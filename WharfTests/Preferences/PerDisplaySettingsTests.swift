import CoreGraphics
import XCTest
@testable import Wharf

/// Per-display override storage. Uses an injected throwaway defaults suite, never
/// `PerDisplaySettings.shared`.
final class PerDisplaySettingsTests: DockyPreferencesTestCase {
    private var displayID: CGDirectDisplayID { CGMainDisplayID() }

    private func makeSettings() -> PerDisplaySettings {
        PerDisplaySettings(defaults: defaults)
    }

    /// Display-keyed behavior needs a display that has a persistent UUID. Headless
    /// runners may not, so those tests skip instead of failing.
    private func requireDisplayKey() throws -> String {
        guard let key = PerDisplaySettings.key(for: displayID) else {
            throw XCTSkip("no display UUID available on this machine")
        }
        return key
    }

    // MARK: DisplayOverride

    func testEmptyOverrideIsEmpty() {
        XCTAssertTrue(DisplayOverride().isEmpty)
    }

    func testZeroFloatOffsetsStillCountAsEmpty() {
        XCTAssertTrue(DisplayOverride(floatOffsetX: 0, floatOffsetY: 0).isEmpty)
    }

    func testAnySingleFieldMakesAnOverrideNonEmpty() {
        XCTAssertFalse(DisplayOverride(position: "left").isEmpty)
        XCTAssertFalse(DisplayOverride(tileSize: 48).isEmpty)
        XCTAssertFalse(DisplayOverride(themeIdentifier: "dark").isEmpty)
        XCTAssertFalse(DisplayOverride(floatOffsetX: 1).isEmpty)
        XCTAssertFalse(DisplayOverride(floatOffsetY: -1).isEmpty)
    }

    func testEmptyStringFieldsAreNotEmpty() {
        XCTAssertFalse(DisplayOverride(position: "").isEmpty)
        XCTAssertFalse(DisplayOverride(themeIdentifier: "").isEmpty)
    }

    func testOverrideCodableRoundTrip() throws {
        let original = DisplayOverride(position: "right", tileSize: 52.5, themeIdentifier: "t", floatOffsetX: 3, floatOffsetY: -4)
        let decoded = try JSONDecoder().decode(DisplayOverride.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testOverrideDecodesFromPartialJSON() throws {
        let decoded = try JSONDecoder().decode(DisplayOverride.self, from: json("{\"tileSize\":40}"))
        XCTAssertEqual(decoded.tileSize, 40)
        XCTAssertNil(decoded.position)
    }

    func testOverrideRejectsWrongFieldTypes() {
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayOverride.self, from: json("{\"tileSize\":\"big\"}")))
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayOverride.self, from: json("{\"position\":5}")))
    }

    // MARK: Display keys

    func testDisplayKeyIsStableAndLooksLikeAUUID() throws {
        let first = try requireDisplayKey()
        XCTAssertEqual(PerDisplaySettings.key(for: displayID), first)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testUnknownDisplayIDHasNoKeyAndNoOverride() {
        let bogus: CGDirectDisplayID = 0xFFFF_FFF0
        XCTAssertNil(PerDisplaySettings.key(for: bogus))
        let settings = makeSettings()
        XCTAssertNil(settings.override(for: bogus))
        XCTAssertNil(settings.override(for: nil))
        settings.setOverride(DisplayOverride(position: "left"), for: bogus)
        XCTAssertNil(defaults.data(forKey: PerDisplaySettings.defaultsKey))
    }

    // MARK: Reading and writing

    func testNoStoredDataYieldsNoOverrides() {
        let settings = makeSettings()
        XCTAssertNil(settings.override(for: displayID))
        XCTAssertNil(settings.position(for: displayID))
        XCTAssertNil(settings.tileSize(for: displayID))
        XCTAssertNil(settings.themeIdentifier(for: displayID))
        XCTAssertEqual(settings.floatOffset(for: displayID), .zero)
    }

    func testSetOverrideRoundTripsThroughStorage() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(position: "left", tileSize: 64, themeIdentifier: "glass"), for: displayID)

        XCTAssertEqual(settings.position(for: displayID), .left)
        XCTAssertEqual(settings.tileSize(for: displayID), 64)
        XCTAssertEqual(settings.themeIdentifier(for: displayID), "glass")

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.override(for: displayID)?.position, "left")
        XCTAssertEqual(reloaded.tileSize(for: displayID), 64)
    }

    func testSettingAnEmptyOverrideRemovesTheEntry() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(position: "right"), for: displayID)
        settings.setOverride(DisplayOverride(), for: displayID)
        XCTAssertNil(settings.override(for: displayID))
        XCTAssertNil(makeSettings().override(for: displayID))
    }

    func testSettingNilRemovesTheEntry() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(tileSize: 30), for: displayID)
        settings.setOverride(nil, for: displayID)
        XCTAssertNil(settings.override(for: displayID))
    }

    func testFloatOffsetRoundTripAndClear() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setFloatOffset(CGSize(width: 12, height: -7), for: displayID)
        XCTAssertEqual(makeSettings().floatOffset(for: displayID), CGSize(width: 12, height: -7))

        settings.setFloatOffset(.zero, for: displayID)
        XCTAssertEqual(settings.floatOffset(for: displayID), .zero)
        XCTAssertNil(settings.override(for: displayID), "a zero offset with no other field leaves nothing to store")
    }

    func testFloatOffsetKeepsOtherFields() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(position: "bottom", tileSize: 50), for: displayID)
        settings.setFloatOffset(CGSize(width: 5, height: 5), for: displayID)
        XCTAssertEqual(settings.override(for: displayID)?.position, "bottom")
        XCTAssertEqual(settings.tileSize(for: displayID), 50)
    }

    func testUnknownPositionStringResolvesToNil() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(position: "diagonal"), for: displayID)
        XCTAssertNil(settings.position(for: displayID))
    }

    func testExtremeFloatOffsetsDoNotTrap() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        for value in [1e300, -1e300, Double.greatestFiniteMagnitude] {
            settings.setFloatOffset(CGSize(width: value, height: value), for: displayID)
            _ = settings.floatOffset(for: displayID)
        }
    }

    func testNonFiniteFloatOffsetDoesNotTrapOrCorruptStorage() throws {
        _ = try requireDisplayKey()
        let settings = makeSettings()
        settings.setOverride(DisplayOverride(position: "left"), for: displayID)
        settings.setFloatOffset(CGSize(width: CGFloat.nan, height: CGFloat.infinity), for: displayID)
        // JSON cannot hold NaN, so the save is skipped; the stored snapshot stays readable.
        XCTAssertNotNil(makeSettings().override(for: displayID))
    }

    // MARK: Hostile stored data

    func testGarbageStoredDataIsIgnored() throws {
        for data in [Data(), Data([0xFF]), json("{"), json("[]"), json("null"), json("{\"a\":1}"), json("{\"a\":{\"tileSize\":\"x\"}}")] {
            defaults.set(data, forKey: PerDisplaySettings.defaultsKey)
            let settings = makeSettings()
            XCTAssertNil(settings.override(for: displayID))
        }
    }

    func testWrongTypeStoredValueIsIgnored() {
        for wrong in ["text", 5, ["a"]] as [Any] {
            defaults.set(wrong, forKey: PerDisplaySettings.defaultsKey)
            XCTAssertNil(makeSettings().override(for: displayID))
        }
    }

    func testStoredEntriesForOtherDisplaysAreIgnoredButPreservedOnSave() throws {
        let key = try requireDisplayKey()
        let other = "00000000-0000-0000-0000-000000000001"
        let seeded: [String: DisplayOverride] = [other: DisplayOverride(position: "right")]
        defaults.set(encoded(seeded), forKey: PerDisplaySettings.defaultsKey)

        let settings = makeSettings()
        XCTAssertNil(settings.override(for: displayID))
        settings.setOverride(DisplayOverride(position: "left"), for: displayID)

        let stored = try JSONDecoder().decode(
            [String: DisplayOverride].self,
            from: try XCTUnwrap(defaults.data(forKey: PerDisplaySettings.defaultsKey))
        )
        XCTAssertEqual(Set(stored.keys), [key, other])
    }

    func testStorageKeyIsThePersistedContract() {
        XCTAssertEqual(PerDisplaySettings.defaultsKey, "wharf.perDisplayOverrides")
    }
}
