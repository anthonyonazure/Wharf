import XCTest
@testable import Wharf

/// Per-instance widget settings (`WidgetSettingValue`, the `WidgetSettings`
/// dictionary), the field schema, and the manifest parser that feeds it.
final class WidgetSettingsTests: DockyPreferencesTestCase {

    // MARK: WidgetSettingValue accessors

    func testTypedAccessorsReturnOnlyTheirOwnCase() {
        XCTAssertEqual(WidgetSettingValue.string("x").stringValue, "x")
        XCTAssertNil(WidgetSettingValue.string("x").doubleValue)
        XCTAssertNil(WidgetSettingValue.string("x").boolValue)
        XCTAssertNil(WidgetSettingValue.string("x").stringListValue)

        XCTAssertEqual(WidgetSettingValue.number(2.5).doubleValue, 2.5)
        XCTAssertNil(WidgetSettingValue.number(2.5).stringValue)

        XCTAssertEqual(WidgetSettingValue.bool(true).boolValue, true)
        XCTAssertNil(WidgetSettingValue.bool(true).doubleValue)

        XCTAssertEqual(WidgetSettingValue.stringList(["a"]).stringListValue, ["a"])
        XCTAssertNil(WidgetSettingValue.stringList(["a"]).stringValue)
    }

    func testCocoaValuesAreFoundationPrimitives() {
        XCTAssertEqual(WidgetSettingValue.string("s").cocoaValue as? String, "s")
        XCTAssertEqual(WidgetSettingValue.number(3).cocoaValue as? Double, 3)
        XCTAssertEqual(WidgetSettingValue.bool(false).cocoaValue as? Bool, false)
        XCTAssertEqual(WidgetSettingValue.stringList(["a", "b"]).cocoaValue as? [String], ["a", "b"])
    }

    func testDictionaryHelpersReadTypedValuesAndMissKeys() {
        let settings: WidgetSettings = [
            "name": .string("Phoenix"),
            "scale": .number(1.5),
            "compact": .bool(true),
            "tags": .stringList(["a", "b"]),
        ]
        XCTAssertEqual(settings.string("name"), "Phoenix")
        XCTAssertEqual(settings.double("scale"), 1.5)
        XCTAssertEqual(settings.bool("compact"), true)
        XCTAssertEqual(settings.stringList("tags"), ["a", "b"])
        XCTAssertNil(settings.string("scale"), "wrong type")
        XCTAssertNil(settings.double("missing"))
    }

    func testAsCocoaConfiguration() {
        let settings: WidgetSettings = ["a": .string("x"), "b": .number(2), "c": .bool(true)]
        let cocoa = settings.asCocoaConfiguration
        XCTAssertEqual(cocoa.count, 3)
        XCTAssertEqual(cocoa["a"] as? String, "x")
        XCTAssertEqual(cocoa["b"] as? Double, 2)
        XCTAssertEqual(cocoa["c"] as? Bool, true)
        XCTAssertEqual(([:] as WidgetSettings).asCocoaConfiguration.count, 0)
    }

    // MARK: WidgetSettingValue Codable

    func testEveryCaseRoundTrips() throws {
        let values: [WidgetSettingValue] = [
            .string(""), .string("hello"), .string("\u{1F642}"), .string(String(repeating: "x", count: 100_000)),
            .number(0), .number(-1.5), .number(1e300), .number(.leastNonzeroMagnitude),
            .bool(true), .bool(false),
            .stringList([]), .stringList(["a", "", "a"]),
        ]
        for value in values {
            let decoded = try JSONDecoder().decode(WidgetSettingValue.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
        }
    }

    func testEncodedShapeIsTypeAndValue() throws {
        let data = try JSONEncoder().encode(WidgetSettingValue.number(4))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "number")
        XCTAssertEqual(object["value"] as? Double, 4)
    }

    func testUnknownTypeThrows() {
        let data = json("{\"type\":\"color\",\"value\":\"#fff\"}")
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettingValue.self, from: data))
    }

    func testMismatchedValueTypeThrows() {
        let cases = [
            "{\"type\":\"string\",\"value\":5}",
            "{\"type\":\"number\",\"value\":\"5\"}",
            "{\"type\":\"bool\",\"value\":\"true\"}",
            "{\"type\":\"stringList\",\"value\":\"a\"}",
            "{\"type\":\"stringList\",\"value\":[1,2]}",
            "{\"type\":\"string\"}",
            "{\"value\":\"x\"}",
            "{}",
            "[]",
            "\"string\"",
            "null",
        ]
        for text in cases {
            XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettingValue.self, from: json(text)), text)
        }
    }

    func testTypeNameIsCaseSensitive() {
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettingValue.self, from: json("{\"type\":\"String\",\"value\":\"x\"}")))
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettingValue.self, from: json("{\"type\":\"stringlist\",\"value\":[]}")))
    }

    func testSettingsDictionaryRoundTrip() throws {
        let settings: WidgetSettings = ["k1": .string("v"), "k2": .number(2), "k3": .stringList(["x"])]
        let decoded = try JSONDecoder().decode(WidgetSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testSettingsDictionaryWithOneBadValueRejectsTheWholeDictionary() {
        let data = json("{\"good\":{\"type\":\"bool\",\"value\":true},\"bad\":{\"type\":\"nope\",\"value\":1}}")
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettings.self, from: data))
    }

    func testSettingsDictionaryDuplicateKeysInJSONDoNotTrap() {
        let data = json("{\"k\":{\"type\":\"number\",\"value\":1},\"k\":{\"type\":\"number\",\"value\":2}}")
        _ = try? JSONDecoder().decode(WidgetSettings.self, from: data)
    }

    func testNonFiniteNumbersCannotBeEncoded() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try JSONEncoder().encode(WidgetSettingValue.number(value)), "\(value)")
        }
    }

    /// A settings text box that parses "nan" or "inf" produces a non-finite number,
    /// the encoder throws, and `persistPinnedItems` answers by deleting the whole
    /// stored list. The dock layout reverts to the legacy app list on next launch.
    func testNonFiniteWidgetSettingMustNotWipeTheStoredPinnedItems() {
        let prefs = makePrefs()
        prefs.pinnedItems = [.app(bundleIdentifier: "com.keep"), .appFolder(id: "custom:folder", bundleIdentifiers: ["a"])]
        XCTAssertNotNil(defaults.data(forKey: PrefKeys.pinnedItems))

        var widget = PinnedTileItem.widget(kind: .weather, ownerBundleIdentifier: "o")
        widget.widgetSettings = ["scale": .number(.nan)]
        prefs.pinnedItems.append(widget)

        // The stored list survives, and the unrepresentable number is dropped
        // rather than blocking the write of every other pinned item.
        let stored = try? defaults.data(forKey: PrefKeys.pinnedItems)
            .map { try JSONDecoder().decode([PinnedTileItem].self, from: $0) }
        XCTAssertEqual(stored?.count, 3)
        XCTAssertEqual(stored?.last?.widgetSettings, WidgetSettings())
        XCTAssertEqual(reload().pinnedItems.count, 3)
    }

    // MARK: Schema types

    func testFieldDefaultsAndIdentity() {
        let field = WidgetSettingsField(id: "city", label: "City", type: .text)
        XCTAssertEqual(field.id, "city")
        XCTAssertNil(field.defaultValue)
        XCTAssertNil(field.options)
    }

    func testFieldCodableRoundTrip() throws {
        let field = WidgetSettingsField(
            id: "units", label: "Units", type: .select,
            defaultValue: .string("metric"),
            options: [.init(value: "metric", label: "Metric"), .init(value: "us", label: "US")]
        )
        let decoded = try JSONDecoder().decode(WidgetSettingsField.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(decoded, field)
    }

    func testFieldTypeRawValues() {
        XCTAssertEqual(WidgetSettingsField.FieldType(rawValue: "text"), .text)
        XCTAssertEqual(WidgetSettingsField.FieldType(rawValue: "number"), .number)
        XCTAssertEqual(WidgetSettingsField.FieldType(rawValue: "toggle"), .toggle)
        XCTAssertEqual(WidgetSettingsField.FieldType(rawValue: "select"), .select)
        XCTAssertNil(WidgetSettingsField.FieldType(rawValue: "slider"))
    }

    func testFieldWithUnknownTypeFailsToDecode() {
        let data = json("{\"id\":\"x\",\"label\":\"X\",\"type\":\"slider\"}")
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSettingsField.self, from: data))
    }

    func testBuiltInKindsAdvertiseSettingsOnlyWhereSchemasExist() {
        for kind in [WidgetKind.weather, .calendar, .nowPlaying] {
            XCTAssertTrue(kind.hasConfigurableSettings, kind.rawValue)
        }
        for kind in [WidgetKind.calendarDate, .reminders, .batteries, .systemStatus, .search, .photoFrame, .layouts, .clock, .audio] {
            XCTAssertFalse(kind.hasConfigurableSettings, kind.rawValue)
        }
    }

    func testUnregisteredExternalKindHasNoConfigurableSettings() {
        XCTAssertFalse(WidgetKind.external("com.never.registered.\(UUID().uuidString)").hasConfigurableSettings)
    }

    // MARK: Manifest parsing

    private func parse(_ text: String) -> [WidgetSettingsField] {
        ExternalWidgetSettingsManifest.parse(json(text))
    }

    func testManifestParsesEveryFieldType() {
        let fields = parse("""
        {"fields":[
          {"id":"city","type":"text","label":"City","default":"Phoenix"},
          {"id":"scale","type":"number","label":"Scale","default":1.5},
          {"id":"compact","type":"toggle","label":"Compact","default":true},
          {"id":"units","type":"select","label":"Units","default":"us",
           "options":[{"value":"us","label":"US"},{"value":"metric"}]}
        ]}
        """)
        XCTAssertEqual(fields.map(\.id), ["city", "scale", "compact", "units"])
        XCTAssertEqual(fields[0].defaultValue, .string("Phoenix"))
        XCTAssertEqual(fields[1].defaultValue, .number(1.5))
        XCTAssertEqual(fields[2].defaultValue, .bool(true))
        XCTAssertEqual(fields[3].options, [.init(value: "us", label: "US"), .init(value: "metric", label: "metric")])
    }

    func testManifestSkipsFieldsWithUnknownTypeOrMissingId() {
        let fields = parse("""
        {"fields":[
          {"id":"ok","type":"text"},
          {"id":"bad","type":"slider"},
          {"type":"text"},
          {"id":"","type":"text"},
          {"id":7,"type":"text"},
          {"id":"notype"}
        ]}
        """)
        XCTAssertEqual(fields.map(\.id), ["ok"])
    }

    func testManifestLabelFallsBackToId() {
        XCTAssertEqual(parse("{\"fields\":[{\"id\":\"city\",\"type\":\"text\"}]}").first?.label, "city")
        XCTAssertEqual(parse("{\"fields\":[{\"id\":\"city\",\"type\":\"text\",\"label\":5}]}").first?.label, "city")
    }

    func testManifestDefaultOfWrongTypeIsDropped() {
        let fields = parse("""
        {"fields":[
          {"id":"a","type":"text","default":5},
          {"id":"b","type":"number","default":"high"},
          {"id":"c","type":"toggle","default":"yes"},
          {"id":"d","type":"select","default":["x"]}
        ]}
        """)
        XCTAssertEqual(fields.count, 4)
        XCTAssertTrue(fields.allSatisfy { $0.defaultValue == nil })
    }

    func testManifestToggleAcceptsZeroOneNumbers() {
        let fields = parse("{\"fields\":[{\"id\":\"a\",\"type\":\"toggle\",\"default\":1},{\"id\":\"b\",\"type\":\"toggle\",\"default\":0}]}")
        XCTAssertEqual(fields.map(\.defaultValue), [.bool(true), .bool(false)])
    }

    func testManifestOptionsIgnoredForNonSelectAndSkippedWhenMalformed() {
        let fields = parse("""
        {"fields":[
          {"id":"t","type":"text","options":[{"value":"x"}]},
          {"id":"s","type":"select","options":[{"value":"ok"},{"label":"no value"},{"value":5}]},
          {"id":"n","type":"select"}
        ]}
        """)
        XCTAssertNil(fields[0].options)
        XCTAssertEqual(fields[1].options?.map(\.value), ["ok"])
        XCTAssertNil(fields[2].options)
    }

    func testManifestGarbageYieldsNoFields() {
        let inputs = [
            "", "{", "null", "[]", "{}", "{\"fields\":null}", "{\"fields\":{}}", "{\"fields\":\"x\"}",
            "{\"fields\":[1,2,3]}", "{\"fields\":[null]}", "{\"fields\":[[]]}",
        ]
        for text in inputs {
            XCTAssertEqual(parse(text).count, 0, text)
        }
        XCTAssertEqual(ExternalWidgetSettingsManifest.parse(Data([0xFF, 0x00, 0xFE])).count, 0)
    }

    func testManifestWithManyFieldsAndDuplicateIds() {
        let fieldsJSON = (0..<2_000).map { _ in "{\"id\":\"dup\",\"type\":\"text\"}" }.joined(separator: ",")
        let fields = parse("{\"fields\":[\(fieldsJSON)]}")
        XCTAssertEqual(fields.count, 2_000, "parser preserves duplicates; the UI keys by index")
    }

    func testManifestHugeNumberDefaultDoesNotTrap() {
        for literal in ["1e308", "-1e308", "1e999", "4.9e-324"] {
            _ = parse("{\"fields\":[{\"id\":\"n\",\"type\":\"number\",\"default\":\(literal)}]}")
        }
    }

    func testManifestLoadFromBundleWithoutResourceIsEmpty() {
        XCTAssertEqual(ExternalWidgetSettingsManifest.load(from: Bundle(for: WidgetSettingsTests.self)).count, 0)
    }

    // MARK: Settings carried on tile items

    func testWidgetSettingsPersistThroughPinnedAndTrailingItems() {
        var pinned = PinnedTileItem.widget(kind: .weather, ownerBundleIdentifier: "o")
        pinned.widgetSettings = ["city": .string("Tempe")]
        var trailing = TrailingTileItem.widget(kind: .clock, ownerBundleIdentifier: "o")
        trailing.widgetSettings = ["24h": .bool(true), "tags": .stringList(["a"])]

        let prefs = makePrefs()
        prefs.pinnedItems = [pinned]
        prefs.trailingItems = [trailing]

        let reloaded = reload()
        XCTAssertEqual(reloaded.pinnedItems.first?.widgetSettings, ["city": .string("Tempe")])
        XCTAssertEqual(reloaded.trailingItems.first?.widgetSettings?.bool("24h"), true)
    }

    func testWidgetTileEffectiveSpanFallsBackToASupportedSpan() {
        let tile = WidgetTile(identifier: "t", title: "Date", kind: .calendarDate, ownerBundleIdentifier: "o", span: .three)
        XCTAssertEqual(tile.effectiveSpan, .one)
        let supported = WidgetTile(identifier: "t", title: "Clock", kind: .clock, ownerBundleIdentifier: "o", span: .four)
        XCTAssertEqual(supported.effectiveSpan, .four)
    }

    func testWidgetKindRawValueRoundTrip() {
        for kind in WidgetKind.builtInCases + [.external("com.example.x")] {
            XCTAssertEqual(WidgetKind(rawValue: kind.rawValue), kind)
        }
        XCTAssertNil(WidgetKind(rawValue: ""))
        XCTAssertNil(WidgetKind(rawValue: "external:"))
        XCTAssertNil(WidgetKind(rawValue: "Clock"))
        XCTAssertEqual(WidgetKind(rawValue: "external:a:b"), .external("a:b"))
    }

    func testTileSpanRawValues() {
        XCTAssertEqual(TileSpan.allCases.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertNil(TileSpan(rawValue: 0))
        XCTAssertNil(TileSpan(rawValue: 5))
        XCTAssertNil(TileSpan(rawValue: -1))
    }
}
