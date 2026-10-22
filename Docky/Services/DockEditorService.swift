//
//  DockEditorService.swift
//  Docky
//

import AppKit
import Foundation

final class DockEditorService {
    static let shared = DockEditorService()

    private static let dockBundleIdentifier = "com.apple.dock"
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let dockPlistFilename = "com.apple.dock.plist"

    private let dockPlistURLOverride: URL?
    private let restartsDockAfterWrite: Bool

    private init() {
        self.dockPlistURLOverride = nil
        self.restartsDockAfterWrite = true
    }

    /// Test seam: point the editor at a scratch plist and keep it from
    /// terminating the real system Dock after a write.
    init(dockPlistURL: URL, restartsDockAfterWrite: Bool = false) {
        self.dockPlistURLOverride = dockPlistURL
        self.restartsDockAfterWrite = restartsDockAfterWrite
    }

    @discardableResult
    func removePinnedApp(bundleIdentifier: String) -> Bool {
        setPinnedApp(bundleIdentifier: bundleIdentifier, pinned: false)
    }

    @discardableResult
    func setPinnedApp(bundleIdentifier: String, pinned: Bool) -> Bool {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != Self.finderBundleIdentifier else {
            return false
        }

        let updated = updateDockPlist { plist in
            guard var apps = plist["persistent-apps"] as? [[String: Any]] else {
                return false
            }

            let existingIndex = apps.firstIndex { entry in
                pinnedAppBundleIdentifier(in: entry) == bundleIdentifier
            }

            if pinned {
                guard existingIndex == nil, let entry = makePinnedAppEntry(bundleIdentifier: bundleIdentifier, plist: plist) else {
                    return false
                }
                apps.append(entry)
            } else {
                guard let existingIndex else {
                    return false
                }
                apps.remove(at: existingIndex)
            }

            plist["persistent-apps"] = apps
            return true
        }

        guard updated else {
            return false
        }

        restartDock()
        refreshTileStore()
        return true
    }

    @discardableResult
    func setPinnedItemOrder(ids: [String]) -> Bool {
        guard !ids.isEmpty else {
            return false
        }

        let updated = updateDockPlist { plist in
            guard let apps = plist["persistent-apps"] as? [[String: Any]],
                  apps.count == ids.count else {
                return false
            }

            // The Dock plist is writable by any process running as the user, so a
            // duplicate GUID must not trap. Entries that share an id are handed
            // out in plist order, one per requested occurrence, so the request
            // must be a permutation of the existing ids and every app survives.
            var remainingByID: [String: [[String: Any]]] = [:]
            for (index, entry) in apps.enumerated() {
                remainingByID[pinnedItemID(in: entry, at: index), default: []].append(entry)
            }

            var orderedApps: [[String: Any]] = []
            orderedApps.reserveCapacity(apps.count)
            for id in ids {
                guard var bucket = remainingByID[id], !bucket.isEmpty else {
                    return false
                }
                orderedApps.append(bucket.removeFirst())
                remainingByID[id] = bucket
            }
            guard orderedApps.count == apps.count else {
                return false
            }

            plist["persistent-apps"] = orderedApps
            return true
        }

        guard updated else {
            return false
        }

        restartDock()
        refreshTileStore()
        return true
    }

    private func updateDockPlist(_ mutate: (inout [String: Any]) -> Bool) -> Bool {
        let url = dockPlistURLOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent(Self.dockPlistFilename)
        return updateDockPlist(at: url, mutate)
    }

    private func updateDockPlist(
        at url: URL,
        _ mutate: (inout [String: Any]) -> Bool
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return false
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = (try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )) as? [String: Any] else {
            return false
        }

        guard mutate(&plist) else {
            return false
        }

        guard let updatedData = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        ) else {
            return false
        }

        do {
            try updatedData.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A scratch plist (test seam) must not spin up the process-wide store,
    /// which would start workspace and media services.
    private func refreshTileStore() {
        guard dockPlistURLOverride == nil else { return }
        TileStore.shared.refreshAfterDockyEditedSystemDock()
    }

    private func restartDock() {
        guard restartsDockAfterWrite else { return }
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .forEach { $0.forceTerminate() }
    }

    func pinnedAppBundleIdentifier(in entry: [String: Any]) -> String? {
        let tileData = entry["tile-data"] as? [String: Any]
        let fileData = tileData?["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let url = urlString.flatMap(URL.init(string:))

        return (tileData?["bundle-identifier"] as? String)
            ?? url.flatMap { $0.isFileURL ? Bundle(url: $0)?.bundleIdentifier : nil }
    }

    func pinnedItemID(in entry: [String: Any], at index: Int) -> String {
        if let guid = (entry["GUID"] as? NSNumber)?.stringValue {
            return guid
        }

        let tileType = (entry["tile-type"] as? String) ?? "unknown"
        let tileData = entry["tile-data"] as? [String: Any] ?? [:]
        let fileData = tileData["file-data"] as? [String: Any]
        let urlString = fileData?["_CFURLString"] as? String
        let bundleIdentifier = tileData["bundle-identifier"] as? String
        let label = tileData["file-label"] as? String

        let signature = [tileType, bundleIdentifier, urlString, label]
            .compactMap { $0?.replacingOccurrences(of: ":", with: "_") }
            .joined(separator: ":")

        if signature.isEmpty {
            return "persistent-apps:\(index):\(tileType)"
        }

        return "persistent-apps:\(index):\(signature)"
    }

    private func makePinnedAppEntry(bundleIdentifier: String, plist: [String: Any]) -> [String: Any]? {
        if let recentApps = plist["recent-apps"] as? [[String: Any]],
           let existing = recentApps.first(where: { pinnedAppBundleIdentifier(in: $0) == bundleIdentifier }) {
            var copied = existing
            copied["GUID"] = NSNumber(value: Int.random(in: 1...Int(UInt32.max)))
            return copied
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let label = FileManager.default.displayName(atPath: appURL.path)
        let fileData: [String: Any] = [
            "_CFURLString": appURL.absoluteString,
            "_CFURLStringType": 15
        ]

        var tileData: [String: Any] = [
            "bundle-identifier": bundleIdentifier,
            "dock-extra": false,
            "file-data": fileData,
            "file-label": label,
            "is-beta": false
        ]

        if let bookmark = try? appURL.bookmarkData() {
            tileData["book"] = bookmark
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: appURL.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            let modValue = plistDateValue(modificationDate)
            tileData["file-mod-date"] = modValue
            tileData["parent-mod-date"] = modValue
        }

        tileData["file-type"] = 1

        return [
            "GUID": NSNumber(value: Int.random(in: 1...Int(UInt32.max))),
            "tile-data": tileData,
            "tile-type": "file-tile"
        ]
    }

    private func plistDateValue(_ date: Date) -> NSNumber {
        NSNumber(value: Int64(date.timeIntervalSinceReferenceDate * 1_000_000))
    }
}
