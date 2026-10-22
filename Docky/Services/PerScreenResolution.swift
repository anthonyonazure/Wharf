//
//  PerScreenResolution.swift
//  Wharf
//
//  The stored shape of a per-display override and the rules that turn it into
//  the value a dock actually uses. Foundation only, so the rules can be
//  checked without a window or a real display: scripts/test-perscreen.sh.
//
//  The rule everywhere is the same: a field the user set for this display
//  wins; anything missing, unreadable or out of range falls back to the
//  global setting. A bad stored value can only ever cost that one field.
//

import Foundation

/// What a single display overrides. Every field is optional; nil means
/// "use the global setting".
struct DisplayOverride: Codable, Equatable {
    var position: String?
    var tileSize: Double?
    var themeIdentifier: String?
    /// Offset from the snapped edge position, in points. Non-zero means the
    /// dock floats.
    var floatOffsetX: Double?
    var floatOffsetY: Double?
    /// Wharf: per-display autohide. Added after the fields above, and
    /// optional, so overrides saved before it existed still load.
    var autohide: Bool?

    init(
        position: String? = nil,
        tileSize: Double? = nil,
        themeIdentifier: String? = nil,
        floatOffsetX: Double? = nil,
        floatOffsetY: Double? = nil,
        autohide: Bool? = nil
    ) {
        self.position = position
        self.tileSize = tileSize
        self.themeIdentifier = themeIdentifier
        self.floatOffsetX = floatOffsetX
        self.floatOffsetY = floatOffsetY
        self.autohide = autohide
    }

    var isEmpty: Bool {
        position == nil
            && tileSize == nil
            && themeIdentifier == nil
            && (floatOffsetX ?? 0) == 0
            && (floatOffsetY ?? 0) == 0
            && autohide == nil
    }

    /// True when any of the three settings the Displays section edits is set.
    /// Float offsets and themes do not count: they are not "settings" the
    /// user turns on with the toggle.
    var hasDockSettings: Bool {
        position != nil || tileSize != nil || autohide != nil
    }
}

enum PerScreenResolution {
    /// Same range as the global Tile Size slider.
    static let tileSizeRange: ClosedRange<Double> = 16...128

    /// Reads the stored overrides one display at a time.
    ///
    /// Decoding the whole dictionary in one go meant a single bad entry (say,
    /// a display that has since been unplugged, written by an older build)
    /// wiped every display's settings. Here a bad entry is salvaged field by
    /// field, and an entry with nothing usable is dropped on its own.
    static func decodeOverrides(_ data: Data?) -> [String: DisplayOverride] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let entries = object as? [String: Any] else { return [:] }

        var result: [String: DisplayOverride] = [:]
        for (key, value) in entries {
            if let decoded = strictDecode(value) {
                result[key] = decoded
            } else if let fields = value as? [String: Any] {
                let salvaged = salvage(fields)
                if !salvaged.isEmpty { result[key] = salvaged }
            }
        }
        return result
    }

    private static func strictDecode(_ value: Any) -> DisplayOverride? {
        // `data(withJSONObject:)` raises rather than throws on a bare string
        // or number, so check first.
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DisplayOverride.self, from: data)
    }

    /// Keeps each field whose stored type is right and drops the rest.
    private static func salvage(_ fields: [String: Any]) -> DisplayOverride {
        DisplayOverride(
            position: fields["position"] as? String,
            tileSize: number(fields["tileSize"]),
            themeIdentifier: fields["themeIdentifier"] as? String,
            floatOffsetX: number(fields["floatOffsetX"]),
            floatOffsetY: number(fields["floatOffsetY"]),
            autohide: boolean(fields["autohide"])
        )
    }

    /// A JSON number that is not a boolean.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    /// A JSON true or false, never a number standing in for one.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Resolution

    /// The edge this dock uses: the override when it names a real edge,
    /// otherwise the global one.
    static func position<Position: RawRepresentable>(override: String?, global: Position) -> Position
    where Position.RawValue == String {
        override.flatMap(Position.init(rawValue:)) ?? global
    }

    /// The tile size this dock uses. An override that is not a finite number
    /// is ignored; one outside the slider's range is pulled back into it.
    static func tileSize(override: Double?, global: Double) -> Double {
        guard let override, override.isFinite else { return global }
        return min(max(override, tileSizeRange.lowerBound), tileSizeRange.upperBound)
    }

    static func autohide(override: Bool?, global: Bool) -> Bool {
        override ?? global
    }

    /// The override to store when the user turns "Use global settings" off:
    /// the dock's current global values, so nothing visibly changes until the
    /// user edits one. Float offset and theme are kept as they were.
    static func seeded(
        from existing: DisplayOverride?,
        globalPosition: String,
        globalTileSize: Double,
        globalAutohide: Bool
    ) -> DisplayOverride {
        var result = existing ?? DisplayOverride()
        result.position = result.position ?? globalPosition
        result.tileSize = tileSize(override: result.tileSize, global: tileSize(override: globalTileSize, global: 48))
        result.autohide = result.autohide ?? globalAutohide
        return result
    }

    /// The override left when the user turns "Use global settings" back on:
    /// the three dock settings cleared, anything else (a float offset, a
    /// theme) untouched. Nil when nothing is left to store.
    static func clearingDockSettings(_ existing: DisplayOverride?) -> DisplayOverride? {
        guard var result = existing else { return nil }
        result.position = nil
        result.tileSize = nil
        result.autohide = nil
        return result.isEmpty ? nil : result
    }

    // MARK: - Editing from a dock's own menu

    /// The override to store when the user picks an edge from a dock's own
    /// menu, or nil when that dock follows the global settings and the
    /// global edge is what should change. A theme or float offset alone does
    /// not count as customized, matching the Displays section's toggle.
    static func settingPosition(_ position: String, in existing: DisplayOverride?) -> DisplayOverride? {
        guard var result = existing, result.hasDockSettings else { return nil }
        result.position = position
        return result
    }

    /// Same rule as `settingPosition`, for hiding.
    static func settingAutohide(_ autohide: Bool, in existing: DisplayOverride?) -> DisplayOverride? {
        guard var result = existing, result.hasDockSettings else { return nil }
        result.autohide = autohide
        return result
    }

    /// Whether magnified icons have room to grow on a dock: the peak size
    /// must beat this dock's own resting size, which a per-display tile size
    /// can make smaller (or larger) than the global one.
    static func magnificationHasRoom(peakSize: Double, restingSize: Double) -> Bool {
        peakSize > restingSize
    }
}
