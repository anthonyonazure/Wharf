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
//  still moves every dock that has not been deliberately customized — the
//  alternative silently strands displays on stale values.
//

import AppKit

// `DisplayOverride` and the fallback rules live in PerScreenResolution.swift,
// which is Foundation only so scripts/test-perscreen.sh can check them.

@Observable
final class PerDisplaySettings {
    static let shared = PerDisplaySettings()

    static let defaultsKey = "wharf.perDisplayOverrides"

    private let defaults: UserDefaults
    private var defaultsKey: String { Self.defaultsKey }
    private var overrides: [String: DisplayOverride] = [:]

    /// `defaults` is injectable so tests can use a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func autohide(for displayID: CGDirectDisplayID?) -> Bool? {
        override(for: displayID)?.autohide
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

    // MARK: - Displays section

    /// Every stored override, connected or not. Reading it inside an
    /// observation closure tracks the whole store, which is what a dock
    /// needs to notice its own entry being created or removed.
    var allOverrides: [String: DisplayOverride] {
        overrides
    }

    /// Override for a display by its stored key. The Displays settings list
    /// works in keys so it never has to resolve a display ID that may have
    /// gone away while the pane was open.
    func override(forKey key: String) -> DisplayOverride? {
        overrides[key]
    }

    func setOverride(_ override: DisplayOverride?, forKey key: String) {
        if let override, !override.isEmpty {
            overrides[key] = override
        } else {
            overrides.removeValue(forKey: key)
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        // Entry by entry, so one unreadable display cannot wipe the others.
        overrides = PerScreenResolution.decodeOverrides(defaults.data(forKey: defaultsKey))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
