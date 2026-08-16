//
//  SystemDockVisibilityService.swift
//  Docky
//
//  Hides the macOS Dock by writing to com.apple.dock preferences
//  (autohide on, large delay, instant animation, no bouncing, no launch
//  animation). The user's previous values are snapshotted before the first
//  overwrite so they can be restored when the preference is turned off or
//  when Docky quits.
//

import AppKit
import Darwin
import Foundation

final class SystemDockVisibilityService {
    static let shared = SystemDockVisibilityService()

    private static let dockDomain = "com.apple.dock" as CFString
    private static let snapshotKey = "docky.systemDockVisibilitySnapshot"
    private static let snapshotNullMarker = "__docky_null__"
    private static let stateFilename = "SystemDockVisibilityState.plist"
    private static let fallbackBundleIdentifier = "gt.quintero.Wharf"
    private static let watchdogAppName = "DockyDockWatchdog.app"

    private static let managedKeys: [String] = [
        "orientation",
        "autohide",
        "autohide-delay",
        "autohide-time-modifier",
        "no-bouncing",
        "launchanim"
    ]

    private static let hiddenValues: [String: CFPropertyList] = [
        "autohide": true as CFBoolean,
        "autohide-delay": 1000.0 as CFNumber,
        "autohide-time-modifier": 0.0 as CFNumber,
        "no-bouncing": true as CFBoolean,
        "launchanim": false as CFBoolean
    ]

    private let defaults = UserDefaults.standard
    private let sessionID = UUID().uuidString.lowercased()
    private var isWatchdogLaunchPendingOrRunning = false

    private init() {}

    private struct VisibilityState {
        let active: Bool
        let ownerPID: pid_t
        let sessionID: String
        let snapshot: [String: Any]?
    }

    var hasSnapshot: Bool {
        defaults.dictionary(forKey: Self.snapshotKey) != nil
    }

    func recoverStaleSnapshotIfNeeded() {
        let state = readVisibilityState()
        let hasStaleActiveState = state?.active == true && !isProcessRunning(state?.ownerPID ?? 0)
        let hasLegacySnapshot = state?.active != true && hasSnapshot

        guard hasStaleActiveState || hasLegacySnapshot else {
            return
        }

        let snapshot = defaults.dictionary(forKey: Self.snapshotKey) ?? state?.snapshot
        restore(using: snapshot)
    }

    func hide() {
        let snapshot = defaults.dictionary(forKey: Self.snapshotKey) ?? captureSnapshot()
        writeActiveState(snapshot: snapshot)
        startWatchdogIfNeeded()
        applyHiddenValues()
        restartDock()
    }

    func setOrientation(_ orientation: DockSettingsService.Orientation) {
        CFPreferencesSetAppValue("orientation" as CFString, orientation.rawValue as CFString, Self.dockDomain)
        CFPreferencesAppSynchronize(Self.dockDomain)
        restartDock()
    }

    func restore() {
        restore(using: defaults.dictionary(forKey: Self.snapshotKey))
    }

    private func restore(using snapshot: [String: Any]?) {
        guard let snapshot else {
            clearActiveState()
            return
        }

        applySnapshot(snapshot)
        defaults.removeObject(forKey: Self.snapshotKey)
        defaults.synchronize()
        restartDock()
        clearActiveState()
    }

    @discardableResult
    private func captureSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in Self.managedKeys {
            if let value = CFPreferencesCopyAppValue(key as CFString, Self.dockDomain) {
                snapshot[key] = value
            } else {
                snapshot[key] = Self.snapshotNullMarker
            }
        }
        defaults.set(snapshot, forKey: Self.snapshotKey)
        defaults.synchronize()
        return snapshot
    }

    private func applyHiddenValues() {
        for (key, value) in Self.hiddenValues {
            CFPreferencesSetAppValue(key as CFString, value, Self.dockDomain)
        }
        CFPreferencesAppSynchronize(Self.dockDomain)
    }

    private func applySnapshot(_ snapshot: [String: Any]) {
        for key in Self.managedKeys {
            let stored = snapshot[key]
            if let marker = stored as? String, marker == Self.snapshotNullMarker {
                CFPreferencesSetAppValue(key as CFString, nil, Self.dockDomain)
            } else if let stored = stored as CFPropertyList? {
                CFPreferencesSetAppValue(key as CFString, stored, Self.dockDomain)
            } else {
                CFPreferencesSetAppValue(key as CFString, nil, Self.dockDomain)
            }
        }
        CFPreferencesAppSynchronize(Self.dockDomain)
    }

    private func restartDock() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .forEach { $0.forceTerminate() }
    }

    private var stateFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Wharf", isDirectory: true)
            .appendingPathComponent(Self.stateFilename)
    }

    private func writeActiveState(snapshot: [String: Any]) {
        guard let stateFileURL else {
            NSLog("[Wharf] Failed to resolve system Dock visibility watchdog state URL")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            let state: [String: Any] = [
                "active": true,
                "ownerPID": Int(ProcessInfo.processInfo.processIdentifier),
                "sessionID": sessionID,
                "snapshot": serializedSnapshot(snapshot)
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: state,
                format: .xml,
                options: 0
            )
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            NSLog("[Wharf] Failed to write system Dock visibility watchdog state: \(error.localizedDescription)")
        }
    }

    private func clearActiveState() {
        guard let stateFileURL, FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: stateFileURL)
            isWatchdogLaunchPendingOrRunning = false
        } catch {
            NSLog("[Wharf] Failed to clear system Dock visibility watchdog state: \(error.localizedDescription)")
        }
    }

    private func readVisibilityState() -> VisibilityState? {
        guard let stateFileURL,
              let data = try? Data(contentsOf: stateFileURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        let snapshot = (plist["snapshot"] as? [String: Any]).map(deserializedSnapshot)
        return VisibilityState(
            active: boolValue(plist["active"]) ?? false,
            ownerPID: pid_t(intValue(plist["ownerPID"]) ?? 0),
            sessionID: plist["sessionID"] as? String ?? "",
            snapshot: snapshot
        )
    }

    private func startWatchdogIfNeeded() {
        guard !isWatchdogLaunchPendingOrRunning else {
            return
        }

        guard let stateFileURL else {
            NSLog("[Wharf] Failed to resolve system Dock visibility watchdog state URL")
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent(Self.watchdogAppName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            NSLog("[Wharf] Failed to locate system Dock visibility watchdog app at \(helperURL.path)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = [
            stateFileURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            sessionID,
            Bundle.main.bundleIdentifier ?? Self.fallbackBundleIdentifier
        ]

        isWatchdogLaunchPendingOrRunning = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] _, error in
            if let error {
                NSLog("[Wharf] Failed to launch system Dock visibility watchdog: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.isWatchdogLaunchPendingOrRunning = false
                }
            }
        }
    }

    private func serializedSnapshot(_ snapshot: [String: Any]) -> [String: Any] {
        var serialized: [String: Any] = [:]
        for key in Self.managedKeys {
            serialized[key] = serializedSnapshotEntry(snapshot[key])
        }
        return serialized
    }

    private func serializedSnapshotEntry(_ stored: Any?) -> [String: Any] {
        if let marker = stored as? String, marker == Self.snapshotNullMarker {
            return ["type": "null"]
        }

        if let stored = stored as? Bool {
            return ["type": "bool", "value": stored]
        }

        if let stored = stored as? NSNumber {
            if CFGetTypeID(stored) == CFBooleanGetTypeID() {
                return ["type": "bool", "value": stored.boolValue]
            }

            return ["type": "number", "value": stored.doubleValue]
        }

        if let stored = stored as? String {
            return ["type": "string", "value": stored]
        }

        return ["type": "null"]
    }

    private func deserializedSnapshot(_ serialized: [String: Any]) -> [String: Any] {
        var snapshot: [String: Any] = [:]
        for key in Self.managedKeys {
            guard let entry = serialized[key] as? [String: Any],
                  let type = entry["type"] as? String else {
                snapshot[key] = Self.snapshotNullMarker
                continue
            }

            switch type {
            case "bool":
                snapshot[key] = boolValue(entry["value"]) ?? false
            case "number":
                snapshot[key] = doubleValue(entry["value"]) ?? 0
            case "string":
                snapshot[key] = entry["value"] as? String ?? ""
            default:
                snapshot[key] = Self.snapshotNullMarker
            }
        }
        return snapshot
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }

        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? NSNumber {
            return value.boolValue
        }

        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }

        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? NSNumber {
            return value.intValue
        }

        if let value = value as? String {
            return Int(value)
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }
}
