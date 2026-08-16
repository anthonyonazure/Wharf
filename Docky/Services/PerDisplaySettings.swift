//
//  PerDisplaySettings.swift
//  Wharf
//
//  Optional per-display overrides for the settings that make sense to differ
//  between docks: which edge it sits on, how big its tiles are, which theme it
//  wears, and whether it floats free of the edge.
//
//  Stored as overrides rather than as a full settings copy per display. A dock
//  with no override inherits the global value, so changing a global setting
//  still moves every dock that has not been deliberately customised — the
//  alternative silently strands displays on stale values.
//

import AppKit

struct DisplayOverride: Codable, Equatable {
    var position: String?
    var tileSize: Double?
    var themeIdentifier: String?
    /// Offset from the snapped edge position, in points. Non-zero means the
    /// dock floats.
    var floatOffsetX: Double?
    var floatOffsetY: Double?

    var isEmpty: Bool {
        position == nil
            && tileSize == nil
            && themeIdentifier == nil
            && (floatOffsetX ?? 0) == 0
            && (floatOffsetY ?? 0) == 0
    }
}

@Observable
final class PerDisplaySettings {
    static let shared = PerDisplaySettings()

    private let defaultsKey = "wharf.perDisplayOverrides"
    private var overrides: [String: DisplayOverride] = [:]

    private init() {
        load()
    }

    /// Keyed by a display's persistent UUID rather than its `CGDirectDisplayID`.
    ///
    /// Display IDs are stable only while a monitor stays attached; macOS may
    /// hand out a different one after a reboot or a cable swap. The UUID
    /// survives both, which is what makes "this dock stays how I set it, even
    /// after unplugging" actually hold.
    static func key(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func override(for displayID: CGDirectDisplayID?) -> DisplayOverride? {
        guard let displayID, let key = Self.key(for: displayID) else { return nil }
        return overrides[key]
    }

    func setOverride(_ override: DisplayOverride?, for displayID: CGDirectDisplayID) {
        guard let key = Self.key(for: displayID) else { return }
        if let override, !override.isEmpty {
            overrides[key] = override
        } else {
            overrides.removeValue(forKey: key)
        }
        save()
    }

    /// Resolved position for a dock, falling back to the global preference.
    func position(for displayID: CGDirectDisplayID?) -> DockWindowPosition? {
        guard let raw = override(for: displayID)?.position else { return nil }
        return DockWindowPosition(rawValue: raw)
    }

    func tileSize(for displayID: CGDirectDisplayID?) -> CGFloat? {
        override(for: displayID)?.tileSize.map { CGFloat($0) }
    }

    func themeIdentifier(for displayID: CGDirectDisplayID?) -> String? {
        override(for: displayID)?.themeIdentifier
    }

    /// How far this dock is pushed off its snapped edge. Zero means snapped.
    func floatOffset(for displayID: CGDirectDisplayID?) -> CGSize {
        guard let override = override(for: displayID) else { return .zero }
        return CGSize(width: override.floatOffsetX ?? 0, height: override.floatOffsetY ?? 0)
    }

    func setFloatOffset(_ offset: CGSize, for displayID: CGDirectDisplayID) {
        var current = override(for: displayID) ?? DisplayOverride()
        current.floatOffsetX = offset.width
        current.floatOffsetY = offset.height
        setOverride(current, for: displayID)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: DisplayOverride].self, from: data) else { return }
        overrides = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
