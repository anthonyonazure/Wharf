import XCTest
@testable import Wharf

/// The nine static decoders that turn `Data` read from the preferences domain
/// into model values. Any process running as the user can write that domain, so
/// every decoder must treat its input as hostile: return nil, never trap.
final class DecoderTests: DockyPreferencesTestCase {

    // MARK: Hostile inputs shared by every decoder

    /// Inputs that no decoder should accept as a valid array or object of its type.
    private var garbage: [(String, Data)] {
        var cases: [(String, Data)] = [
            ("empty", Data()),
            ("single NUL", Data([0x00])),
            ("high bytes", Data([0xFF, 0xFE, 0xFD, 0xFC])),
            ("lone open brace", json("{")),
            ("lone open bracket", json("[")),
            ("truncated array", json("[{\"id\":")),
            ("truncated string", json("[{\"id\":\"abc")),
            ("bare null", json("null")),
            ("bare string", json("\"hello\"")),
            ("bare number", json("12345")),
            ("bare true", json("true")),
            ("array of numbers", json("[1,2,3]")),
            ("array of null", json("[null]")),
            ("array of arrays", json("[[],[]]")),
            ("array of empty objects", json("[{}]")),
            ("whitespace only", json("   \n\t ")),
            ("trailing comma", json("[{},]")),
            ("single quotes", json("[{'id':'x'}]")),
            ("NaN literal", json("[{\"red\":NaN}]")),
            ("hex literal", json("0xDEADBEEF")),
            ("xml", json("<plist version=\"1.0\"><dict/></plist>")),
            ("binary plist magic", Data("bplist00".utf8) + Data(repeating: 0, count: 32)),
            ("utf16", "[]".data(using: .utf16) ?? Data()),
            ("deep nesting", Data(String(repeating: "[", count: 5_000).utf8)),
            ("deep nesting closed", Data((String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)).utf8)),
            ("1 MB of A", Data(repeating: 0x41, count: 1_000_000)),
        ]
        // Fixed pseudo-random bytes keep the run deterministic.
        cases.append(("pattern 64 KB", Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) })))
        return cases
    }

    private func assertArrayDecoderRejectsGarbage<T>(
        _ name: String,
        _ decode: (Data?) -> [T]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(decode(nil), "\(name) nil", file: file, line: line)
        for (label, data) in garbage {
            // `[]`-shaped hostile input such as `[[],[]]` must not decode to elements.
            let result = decode(data)
            XCTAssertTrue(result == nil || result!.isEmpty, "\(name) accepted \(label)", file: file, line: line)
        }
    }

    // MARK: decodeColor

    func testDecodeColorNilAndGarbage() {
        XCTAssertNil(DockyPreferences.decodeColor(from: nil))
        for (label, data) in garbage {
            XCTAssertNil(DockyPreferences.decodeColor(from: data), label)
        }
    }

    func testDecodeColorValid() {
        let color = DockyPreferences.decodeColor(from: json("{\"red\":0.1,\"green\":0.5,\"blue\":1}"))
        XCTAssertEqual(color, DockColor(red: 0.1, green: 0.5, blue: 1))
    }

    func testDecodeColorRoundTripsEncoderOutput() {
        let original = DockColor(red: 0.25, green: 0.5, blue: 0.75)
        XCTAssertEqual(DockyPreferences.decodeColor(from: encoded(original)), original)
    }

    func testDecodeColorMissingComponentIsNil() {
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{\"red\":1,\"green\":1}")))
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{\"red\":1,\"blue\":1}")))
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{}")))
    }

    func testDecodeColorWrongComponentTypesAreNil() {
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{\"red\":\"1\",\"green\":0,\"blue\":0}")))
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{\"red\":null,\"green\":0,\"blue\":0}")))
        XCTAssertNil(DockyPreferences.decodeColor(from: json("{\"red\":[1],\"green\":0,\"blue\":0}")))
    }

    func testDecodeColorIgnoresUnknownFields() {
        let data = json("{\"red\":1,\"green\":0,\"blue\":0,\"alpha\":0.2,\"name\":\"red\"}")
        XCTAssertEqual(DockyPreferences.decodeColor(from: data), DockColor(red: 1, green: 0, blue: 0))
    }

    func testDecodeColorOutOfRangeComponentsDecodeButNsColorDoesNotTrap() throws {
        let hostile = [-1.0, 2.0, 1e300, -1e300]
        for value in hostile {
            let data = json("{\"red\":\(value),\"green\":\(value),\"blue\":\(value)}")
            let color = try XCTUnwrap(DockyPreferences.decodeColor(from: data), "\(value)")
            _ = color.nsColor
        }
    }

    func testDecodeColorOverflowingExponentDoesNotTrap() {
        _ = DockyPreferences.decodeColor(from: json("{\"red\":1e999,\"green\":0,\"blue\":0}"))
        _ = DockyPreferences.decodeColor(from: json("{\"red\":-1e999,\"green\":0,\"blue\":0}"))
    }

    func testDockColorFromNSColorConvertsSystemColors() throws {
        let red = try XCTUnwrap(DockColor(nsColor: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)))
        XCTAssertEqual(red.red, 1, accuracy: 0.001)
        XCTAssertEqual(red.green, 0, accuracy: 0.001)
        XCTAssertNotNil(DockColor(nsColor: .windowBackgroundColor))
        XCTAssertNotNil(DockColor(nsColor: .labelColor))
    }

    func testDockColorNSColorHasFullAlpha() {
        let ns = DockColor(red: 0.2, green: 0.4, blue: 0.6).nsColor
        XCTAssertEqual(ns.alphaComponent, 1, accuracy: 0.0001)
    }

    // MARK: decodeKeyboardShortcut

    func testDecodeShortcutNilAndGarbage() {
        XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: nil))
        for (label, data) in garbage {
            XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: data), label)
        }
    }

    func testDecodeShortcutValid() {
        let data = json("{\"keyCode\":48,\"modifierFlagsRawValue\":524288}")
        let shortcut = DockyPreferences.decodeKeyboardShortcut(from: data)
        XCTAssertEqual(shortcut?.keyCode, 48)
        XCTAssertEqual(shortcut?.modifierFlags, [.option])
    }

    /// Regression for the September audit.
    func testDecodeShortcutOutOfRangeKeyCodeIsNilNotATrap() {
        for code in ["-1", "65536", "70000", "4294967296", "9223372036854775807", "-9223372036854775808", "1e10", "1.5"] {
            let data = json("{\"keyCode\":\(code),\"modifierFlagsRawValue\":524288}")
            XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: data), code)
        }
    }

    func testDecodeShortcutBoundaryKeyCodes() {
        for code in [0, 1, 65534, 65535] {
            let data = json("{\"keyCode\":\(code),\"modifierFlagsRawValue\":524288}")
            XCTAssertEqual(DockyPreferences.decodeKeyboardShortcut(from: data)?.keyCode, UInt16(code), "\(code)")
        }
    }

    func testDecodeShortcutNegativeOrOverflowingModifierBitsIsNil() {
        for bits in ["-1", "18446744073709551616", "1e30", "\"x\"", "null"] {
            let data = json("{\"keyCode\":1,\"modifierFlagsRawValue\":\(bits)}")
            XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: data), bits)
        }
    }

    func testDecodeShortcutMissingFieldsIsNil() {
        XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: json("{\"keyCode\":1}")))
        XCTAssertNil(DockyPreferences.decodeKeyboardShortcut(from: json("{\"modifierFlagsRawValue\":1}")))
    }

    func testDecodeShortcutMaximumModifierBitsDoesNotTrap() {
        let data = json("{\"keyCode\":1,\"modifierFlagsRawValue\":18446744073709551615}")
        let shortcut = DockyPreferences.decodeKeyboardShortcut(from: data)
        XCTAssertNotNil(shortcut)
        XCTAssertEqual(shortcut?.modifierFlags, [.command, .option, .control, .shift])
    }

    // MARK: Array decoders: shared hostile-input behavior

    func testEveryArrayDecoderRejectsNilAndGarbage() {
        assertArrayDecoderRejectsGarbage("widgetPlacements", DockyPreferences.decodeWidgetPlacements)
        assertArrayDecoderRejectsGarbage("appWidgetDisplays", DockyPreferences.decodeAppWidgetDisplays)
        assertArrayDecoderRejectsGarbage("appIconOverrides", DockyPreferences.decodeAppIconOverrides)
        assertArrayDecoderRejectsGarbage("trashIconOverrides", DockyPreferences.decodeTrashIconOverrides)
        assertArrayDecoderRejectsGarbage("folderIconOverrides", DockyPreferences.decodeFolderIconOverrides)
        assertArrayDecoderRejectsGarbage("pinnedItems", DockyPreferences.decodePinnedItems)
        assertArrayDecoderRejectsGarbage("trailingItems", DockyPreferences.decodeTrailingItems)
    }

    func testEveryArrayDecoderAcceptsEmptyArrayAsEmpty() {
        let empty = json("[]")
        XCTAssertEqual(DockyPreferences.decodeWidgetPlacements(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodeAppWidgetDisplays(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodeAppIconOverrides(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodeTrashIconOverrides(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodeFolderIconOverrides(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: empty), [])
        XCTAssertEqual(DockyPreferences.decodeTrailingItems(from: empty), [])
    }

    func testEveryArrayDecoderRejectsAnObjectInPlaceOfAnArray() {
        let object = json("{\"id\":\"x\",\"kind\":\"app\"}")
        XCTAssertNil(DockyPreferences.decodeWidgetPlacements(from: object))
        XCTAssertNil(DockyPreferences.decodeAppWidgetDisplays(from: object))
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: object))
        XCTAssertNil(DockyPreferences.decodeTrashIconOverrides(from: object))
        XCTAssertNil(DockyPreferences.decodeFolderIconOverrides(from: object))
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: object))
        XCTAssertNil(DockyPreferences.decodeTrailingItems(from: object))
    }

    // MARK: decodeWidgetPlacements

    func testDecodeWidgetPlacementsValid() {
        let data = json("[{\"kind\":\"clock\",\"ownerBundleIdentifier\":\"com.x\",\"span\":3}]")
        XCTAssertEqual(
            DockyPreferences.decodeWidgetPlacements(from: data),
            [WidgetPlacement(kind: .clock, ownerBundleIdentifier: "com.x", span: .three)]
        )
    }

    func testDecodeWidgetPlacementsEveryBuiltInKindAndSpan() {
        var placements: [WidgetPlacement] = []
        for kind in WidgetKind.builtInCases {
            for span in TileSpan.allCases {
                placements.append(WidgetPlacement(kind: kind, ownerBundleIdentifier: "owner.\(kind.rawValue)", span: span))
            }
        }
        XCTAssertEqual(DockyPreferences.decodeWidgetPlacements(from: encoded(placements)), placements)
    }

    func testDecodeWidgetPlacementsExternalKind() {
        let data = json("[{\"kind\":\"external:com.example.Widget\",\"ownerBundleIdentifier\":\"o\",\"span\":2}]")
        XCTAssertEqual(
            DockyPreferences.decodeWidgetPlacements(from: data)?.first?.kind,
            .external("com.example.Widget")
        )
    }

    func testDecodeWidgetPlacementsBadSpanRejectsTheWholeArray() {
        for span in ["0", "5", "-1", "99", "1.5", "\"3\"", "null"] {
            let data = json("[{\"kind\":\"clock\",\"ownerBundleIdentifier\":\"o\",\"span\":\(span)}]")
            XCTAssertNil(DockyPreferences.decodeWidgetPlacements(from: data), span)
        }
    }

    func testDecodeWidgetPlacementsUnknownKindRejectsTheWholeArray() {
        for kind in ["\"hologram\"", "\"external:\"", "\"\"", "5", "null"] {
            let data = json("[{\"kind\":\(kind),\"ownerBundleIdentifier\":\"o\",\"span\":1}]")
            XCTAssertNil(DockyPreferences.decodeWidgetPlacements(from: data), kind)
        }
    }

    /// Documents the all-or-nothing behavior: one unreadable element discards the
    /// rest of the user's widgets. No crash, but a newer build's widget kind makes
    /// an older build forget every placement.
    func testDecodeWidgetPlacementsOneBadElementDiscardsValidNeighbours() {
        let data = json("""
        [{"kind":"clock","ownerBundleIdentifier":"a","span":1},
         {"kind":"hologram","ownerBundleIdentifier":"b","span":1}]
        """)
        XCTAssertNil(DockyPreferences.decodeWidgetPlacements(from: data))
    }

    func testDecodeWidgetPlacementsDuplicatesArePreserved() {
        let one = WidgetPlacement(kind: .clock, ownerBundleIdentifier: "dup", span: .one)
        let decoded = DockyPreferences.decodeWidgetPlacements(from: encoded([one, one, one]))
        XCTAssertEqual(decoded?.count, 3)
    }

    func testDecodeWidgetPlacementsHugeArray() {
        let placements = (0..<5_000).map {
            WidgetPlacement(kind: .weather, ownerBundleIdentifier: "owner.\($0)", span: .two)
        }
        XCTAssertEqual(DockyPreferences.decodeWidgetPlacements(from: encoded(placements))?.count, 5_000)
    }

    // MARK: decodeAppWidgetDisplays

    func testDecodeAppWidgetDisplaysValidAndRejects() {
        let valid = json("[{\"bundleIdentifier\":\"com.x\",\"kind\":\"weather\",\"span\":1}]")
        XCTAssertEqual(
            DockyPreferences.decodeAppWidgetDisplays(from: valid),
            [AppWidgetDisplay(bundleIdentifier: "com.x", kind: .weather, span: .one)]
        )
        let badSpan = json("[{\"bundleIdentifier\":\"com.x\",\"kind\":\"weather\",\"span\":7}]")
        XCTAssertNil(DockyPreferences.decodeAppWidgetDisplays(from: badSpan))
        let missing = json("[{\"kind\":\"weather\",\"span\":1}]")
        XCTAssertNil(DockyPreferences.decodeAppWidgetDisplays(from: missing))
    }

    func testDecodeAppWidgetDisplaysDuplicateBundlesArePreserved() {
        let display = AppWidgetDisplay(bundleIdentifier: "dup", kind: .clock, span: .one)
        XCTAssertEqual(DockyPreferences.decodeAppWidgetDisplays(from: encoded([display, display]))?.count, 2)
    }

    // MARK: decodeAppIconOverrides

    func testDecodeAppIconOverridesValid() {
        let data = json("[{\"bundleIdentifier\":\"com.a\",\"iconPath\":\"/tmp/a.png\",\"paddingFraction\":0.1}]")
        XCTAssertEqual(
            DockyPreferences.decodeAppIconOverrides(from: data),
            [AppIconOverride(bundleIdentifier: "com.a", iconPath: "/tmp/a.png", paddingFraction: 0.1)]
        )
    }

    func testDecodeAppIconOverridesLegacyBlobWithoutPadding() {
        let data = json("[{\"bundleIdentifier\":\"com.a\",\"iconPath\":\"/tmp/a.png\"}]")
        XCTAssertEqual(DockyPreferences.decodeAppIconOverrides(from: data)?.first?.paddingFraction, nil)
    }

    func testDecodeAppIconOverridesMissingRequiredFieldRejects() {
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: json("[{\"iconPath\":\"/x\"}]")))
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: json("[{\"bundleIdentifier\":\"a\"}]")))
    }

    func testDecodeAppIconOverridesWrongTypesReject() {
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: json("[{\"bundleIdentifier\":1,\"iconPath\":\"/x\"}]")))
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: json("[{\"bundleIdentifier\":\"a\",\"iconPath\":false}]")))
        XCTAssertNil(DockyPreferences.decodeAppIconOverrides(from: json("[{\"bundleIdentifier\":\"a\",\"iconPath\":\"/x\",\"paddingFraction\":\"0.1\"}]")))
    }

    func testDecodeAppIconOverridesAcceptsExtremePaddingWithoutTrapping() {
        for padding in ["1e300", "-1e300", "-5", "99", "0"] {
            let data = json("[{\"bundleIdentifier\":\"a\",\"iconPath\":\"/x\",\"paddingFraction\":\(padding)}]")
            XCTAssertNotNil(DockyPreferences.decodeAppIconOverrides(from: data), padding)
        }
    }

    func testDecodeAppIconOverridesDuplicatesArePreserved() {
        let overrides = [
            AppIconOverride(bundleIdentifier: "dup", iconPath: "/first"),
            AppIconOverride(bundleIdentifier: "dup", iconPath: "/second"),
        ]
        XCTAssertEqual(DockyPreferences.decodeAppIconOverrides(from: encoded(overrides)), overrides)
    }

    func testDecodeAppIconOverridesHugeArray() {
        let overrides = (0..<5_000).map { AppIconOverride(bundleIdentifier: "app.\($0)", iconPath: "/icons/\($0).png") }
        XCTAssertEqual(DockyPreferences.decodeAppIconOverrides(from: encoded(overrides))?.count, 5_000)
    }

    // MARK: decodeTrashIconOverrides

    func testDecodeTrashIconOverridesValid() {
        let data = json("[{\"state\":\"empty\",\"iconPath\":\"/e\"},{\"state\":\"full\",\"iconPath\":\"/f\",\"paddingFraction\":0.2}]")
        let decoded = DockyPreferences.decodeTrashIconOverrides(from: data)
        XCTAssertEqual(decoded?.map(\.state), [.empty, .full])
        XCTAssertEqual(decoded?.last?.paddingFraction, 0.2)
    }

    func testDecodeTrashIconOverridesUnknownStateRejects() {
        for state in ["\"half\"", "\"EMPTY\"", "\"\"", "0", "null"] {
            let data = json("[{\"state\":\(state),\"iconPath\":\"/x\"}]")
            XCTAssertNil(DockyPreferences.decodeTrashIconOverrides(from: data), state)
        }
    }

    func testDecodeTrashIconOverridesDuplicateStatesArePreserved() {
        let data = json("""
        [{"state":"empty","iconPath":"/a"},{"state":"empty","iconPath":"/b"},{"state":"empty","iconPath":"/c"}]
        """)
        XCTAssertEqual(DockyPreferences.decodeTrashIconOverrides(from: data)?.count, 3)
    }

    // MARK: decodeFolderIconOverrides

    func testDecodeFolderIconOverridesValidAndRejects() {
        let valid = json("[{\"folderPath\":\"/Users/x/Docs\",\"iconPath\":\"/i.png\"}]")
        XCTAssertEqual(
            DockyPreferences.decodeFolderIconOverrides(from: valid),
            [FolderIconOverride(folderPath: "/Users/x/Docs", iconPath: "/i.png")]
        )
        XCTAssertNil(DockyPreferences.decodeFolderIconOverrides(from: json("[{\"folderPath\":\"/x\"}]")))
        XCTAssertNil(DockyPreferences.decodeFolderIconOverrides(from: json("[{\"iconPath\":\"/x\"}]")))
    }

    func testDecodeFolderIconOverridesDuplicatePathsArePreserved() {
        let overrides = [
            FolderIconOverride(folderPath: "/dup", iconPath: "/1"),
            FolderIconOverride(folderPath: "/dup", iconPath: "/2"),
        ]
        XCTAssertEqual(DockyPreferences.decodeFolderIconOverrides(from: encoded(overrides)), overrides)
    }

    // MARK: decodePinnedItems

    private let minimalPinned = "{\"id\":\"%@\",\"kind\":\"%@\",\"folderBundleIdentifiers\":[],\"hiddenWidgetOwnerBundleIdentifiers\":[]}"

    func testDecodePinnedItemsEveryKindRoundTrips() {
        let items: [PinnedTileItem] = [
            .app(bundleIdentifier: "com.apple.finder"),
            .appFolder(id: "custom:1", displayName: "Work", bundleIdentifiers: ["a", "b"], displayMode: .stack, contentViewMode: .fan),
            .widget(kind: .clock, ownerBundleIdentifier: "owner", span: .two),
            .launchpad(id: "custom:lp"),
            .startMenu(id: "custom:sm"),
            .smartStack(hiddenWidgetOwnerBundleIdentifiers: ["x"]),
            .spacer(),
            .flexibleSpacer(),
            .divider(),
        ]
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: encoded(items)), items)
    }

    func testDecodePinnedItemsMinimalLegacyBlob() {
        let element = String(format: minimalPinned, "app:x", "app")
        let items = DockyPreferences.decodePinnedItems(from: json("[\(element)]"))
        XCTAssertEqual(items?.count, 1)
        XCTAssertNil(items?.first?.widgetSettings)
    }

    func testDecodePinnedItemsUnknownKindRejectsTheWholeArray() {
        let good = String(format: minimalPinned, "app:x", "app")
        let bad = String(format: minimalPinned, "z", "teleporter")
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: json("[\(good),\(bad)]")))
    }

    func testDecodePinnedItemsMissingRequiredFieldsReject() {
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: json("[{\"kind\":\"app\"}]")))
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: json("[{\"id\":\"x\"}]")))
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: json("[{\"id\":\"x\",\"kind\":\"app\"}]")))
    }

    func testDecodePinnedItemsLenientFolderViewModeKeepsTheItem() {
        let data = json("""
        [{"id":"f","kind":"appFolder","folderBundleIdentifiers":["a"],"hiddenWidgetOwnerBundleIdentifiers":[],
          "appFolderDisplayMode":"grid","folderContentViewMode":"holographic"}]
        """)
        let items = DockyPreferences.decodePinnedItems(from: data)
        XCTAssertEqual(items?.first?.folderContentViewMode, .grid)
    }

    func testDecodePinnedItemsStrictAppFolderDisplayModeRejects() {
        let data = json("""
        [{"id":"f","kind":"appFolder","folderBundleIdentifiers":[],"hiddenWidgetOwnerBundleIdentifiers":[],
          "appFolderDisplayMode":"carousel"}]
        """)
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: data))
    }

    func testDecodePinnedItemsWidgetSettingsRoundTrip() {
        var item = PinnedTileItem.widget(kind: .weather, ownerBundleIdentifier: "o", span: .three)
        item.widgetSettings = [
            "city": .string("Phoenix"),
            "units": .number(1),
            "compact": .bool(true),
            "tags": .stringList(["a", "b"]),
        ]
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: encoded([item])), [item])
    }

    func testDecodePinnedItemsUnknownWidgetSettingTypeRejects() {
        let data = json("""
        [{"id":"w","kind":"widget","folderBundleIdentifiers":[],"hiddenWidgetOwnerBundleIdentifiers":[],
          "widgetKind":"clock","widgetOwnerBundleIdentifier":"o","widgetSpan":1,
          "widgetSettings":{"k":{"type":"matrix","value":1}}}]
        """)
        XCTAssertNil(DockyPreferences.decodePinnedItems(from: data))
    }

    func testDecodePinnedItemsDuplicateIdsArePreserved() {
        let items = [PinnedTileItem.app(bundleIdentifier: "dup"), PinnedTileItem.app(bundleIdentifier: "dup")]
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: encoded(items))?.count, 2)
    }

    func testDecodePinnedItemsHugeArray() {
        let items = (0..<5_000).map { PinnedTileItem.app(bundleIdentifier: "app.\($0)") }
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: encoded(items))?.count, 5_000)
    }

    func testDecodePinnedItemsHugeFolderMembership() {
        let ids = (0..<20_000).map { "app.\($0)" }
        let item = PinnedTileItem.appFolder(id: "custom:big", bundleIdentifiers: ids)
        XCTAssertEqual(DockyPreferences.decodePinnedItems(from: encoded([item]))?.first?.folderBundleIdentifiers.count, 20_000)
    }

    // MARK: decodeTrailingItems

    func testDecodeTrailingItemsEveryKindRoundTrips() throws {
        let url = try XCTUnwrap(URL(string: "file:///Users/someone/Downloads/"))
        let items: [TrailingTileItem] = [
            .folder(sourceTileID: "tile-1", displayMode: .folder, contentViewMode: .list, sortMode: .name),
            .folder(id: "custom-folder:1", url: url, displayName: "Downloads"),
            .trash(),
            .widget(kind: .audio, ownerBundleIdentifier: "o", span: .four),
            .smartStack(),
            .spacer(),
            .flexibleSpacer(),
            .divider(),
        ]
        let decoded = try XCTUnwrap(DockyPreferences.decodeTrailingItems(from: encoded(items)))
        XCTAssertEqual(decoded.count, items.count)
        // Smart stack and widget factories mint random ids, so compare the encoded form.
        XCTAssertEqual(decoded, items)
    }

    func testDecodeTrailingItemsMinimalBlob() {
        let data = json("[{\"id\":\"trash\",\"kind\":\"trash\",\"hiddenWidgetOwnerBundleIdentifiers\":[]}]")
        XCTAssertEqual(DockyPreferences.decodeTrailingItems(from: data), [.trash()])
    }

    func testDecodeTrailingItemsUnknownKindRejects() {
        let data = json("[{\"id\":\"x\",\"kind\":\"portal\",\"hiddenWidgetOwnerBundleIdentifiers\":[]}]")
        XCTAssertNil(DockyPreferences.decodeTrailingItems(from: data))
    }

    func testDecodeTrailingItemsUnknownSortModeRejects() {
        let data = json("""
        [{"id":"f","kind":"folder","hiddenWidgetOwnerBundleIdentifiers":[],"folderSortMode":"vibes"}]
        """)
        XCTAssertNil(DockyPreferences.decodeTrailingItems(from: data))
    }

    func testDecodeTrailingItemsHostileFolderURLsDoNotTrap() {
        for url in ["\"\"", "\"not a url\"", "\"file:///\"", "\"http://[::1\"", "5", "null", "\"\u{0}\""] {
            let data = json("[{\"id\":\"f\",\"kind\":\"folder\",\"hiddenWidgetOwnerBundleIdentifiers\":[],\"folderURL\":\(url)}]")
            _ = DockyPreferences.decodeTrailingItems(from: data)
        }
    }

    func testDecodeTrailingItemsDuplicateIdsArePreserved() {
        let items = [TrailingTileItem.trash(), TrailingTileItem.trash(), TrailingTileItem.trash()]
        XCTAssertEqual(DockyPreferences.decodeTrailingItems(from: encoded(items))?.count, 3)
    }

    func testDecodeTrailingItemsHugeArray() {
        let items = (0..<5_000).map { TrailingTileItem.folder(sourceTileID: "tile-\($0)") }
        XCTAssertEqual(DockyPreferences.decodeTrailingItems(from: encoded(items))?.count, 5_000)
    }

    // MARK: Init integration

    func testInitSurvivesEveryGarbageBlobInEveryDataKey() {
        let dataKeys = [
            PrefKeys.tileHoverBackgroundColor, PrefKeys.tileActiveBackgroundColor, PrefKeys.windowTintColor,
            PrefKeys.activeIndicatorColor, PrefKeys.dividerColor, PrefKeys.windowBorderColor, PrefKeys.iconShadowColor,
            PrefKeys.appIconOverrides, PrefKeys.trashIconOverrides, PrefKeys.folderIconOverrides,
            PrefKeys.launchpadShortcut, PrefKeys.windowSwitcherShortcut,
            PrefKeys.pinnedItems, PrefKeys.widgetPlacements, PrefKeys.appWidgetDisplays, PrefKeys.trailingItems,
        ]
        // Skip the 1 MB case: it is covered by the decoder tests and would be
        // written once per key per iteration.
        for (_, data) in garbage where data.count < 100_000 {
            for key in dataKeys {
                defaults.set(data, forKey: key)
            }
            let prefs = makePrefs()
            XCTAssertNil(prefs.windowTintColor)
            XCTAssertEqual(prefs.pinnedItems, [])
            XCTAssertEqual(prefs.trailingItems, [])
            XCTAssertEqual(prefs.windowSwitcherShortcut, PrefDefaults.windowSwitcherShortcut)
            XCTAssertEqual(prefs.launchpadShortcut, .empty)
        }
    }

    func testInitSurvivesNonDataValuesInEveryDataKey() {
        let dataKeys = [
            PrefKeys.windowTintColor, PrefKeys.appIconOverrides, PrefKeys.pinnedItems,
            PrefKeys.widgetPlacements, PrefKeys.trailingItems, PrefKeys.windowSwitcherShortcut,
        ]
        for wrong in ["a string", 42, 3.14, true, ["a", "b"], ["k": "v"]] as [Any] {
            for key in dataKeys {
                defaults.set(wrong, forKey: key)
            }
            let prefs = makePrefs()
            XCTAssertNil(prefs.windowTintColor, "\(type(of: wrong))")
            XCTAssertEqual(prefs.appIconOverrides, [], "\(type(of: wrong))")
            XCTAssertEqual(prefs.widgetPlacements, [], "\(type(of: wrong))")
        }
    }

    func testInitLoadsValidBlobsFromStorage() {
        defaults.set(encoded(DockColor(red: 1, green: 0, blue: 0)), forKey: PrefKeys.windowTintColor)
        defaults.set(encoded([AppIconOverride(bundleIdentifier: "a", iconPath: "/x")]), forKey: PrefKeys.appIconOverrides)
        defaults.set(encoded(KeyboardShortcut(keyCode: 12, modifierFlags: [.command])), forKey: PrefKeys.launchpadShortcut)
        defaults.set(encoded([TrailingTileItem.trash()]), forKey: PrefKeys.trailingItems)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.windowTintColor, DockColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(prefs.appIconOverrides.map(\.bundleIdentifier), ["a"])
        XCTAssertEqual(prefs.launchpadShortcut.keyCode, 12)
        XCTAssertEqual(prefs.trailingItems, [.trash()])
    }
}
