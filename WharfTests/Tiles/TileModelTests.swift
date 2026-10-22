import XCTest
@testable import Wharf

/// Value-type behavior of the tile model: identity, equality, spans,
/// WidgetKind persistence strings and the persisted item factories.
@MainActor
final class TileModelTests: XCTestCase {
    // MARK: - Tile identity

    func testDefaultTileIDIsAUUIDString() {
        let tile = Tile(content: .spacer)
        XCTAssertNotNil(UUID(uuidString: tile.id))
    }

    func testDefaultTileIDsAreUniqueByConstruction() {
        let ids = (0..<1_000).map { _ in Tile(content: .spacer).id }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testExplicitTileIDIsKept() {
        XCTAssertEqual(Tile(id: "pinned:com.apple.finder", content: .divider).id, "pinned:com.apple.finder")
    }

    func testTileEqualityComparesIDAndContent() {
        let a = Tile(id: "x", content: .spacer)
        XCTAssertEqual(a, Tile(id: "x", content: .spacer))
        XCTAssertNotEqual(a, Tile(id: "y", content: .spacer))
        XCTAssertNotEqual(a, Tile(id: "x", content: .divider))
    }

    func testTileContentCanBeMutatedWithoutChangingID() {
        var tile = Tile(id: "x", content: .spacer)
        tile.content = .trash
        XCTAssertEqual(tile.id, "x")
        XCTAssertEqual(tile.content, .trash)
    }

    func testTileIsIdentifiableByItsID() {
        let tile = Tile(id: "abc", content: .trash)
        XCTAssertEqual(tile.id, "abc")
        let list: [any Identifiable] = [tile]
        XCTAssertEqual(list.count, 1)
    }

    func testStructuralContentCasesAreAllDistinct() {
        let cases: [TileContent] = [.spacer, .flexibleSpacer, .divider, .trash]
        for (i, a) in cases.enumerated() {
            for (j, b) in cases.enumerated() {
                if i == j { XCTAssertEqual(a, b) } else { XCTAssertNotEqual(a, b) }
            }
        }
    }

    func testAppContentEquality() {
        let a = TileContent.app(AppTile(bundleIdentifier: "a", displayName: "A"))
        XCTAssertEqual(a, .app(AppTile(bundleIdentifier: "a", displayName: "A")))
        XCTAssertNotEqual(a, .app(AppTile(bundleIdentifier: "a", displayName: "B")))
        XCTAssertNotEqual(a, .app(AppTile(bundleIdentifier: "b", displayName: "A")))
    }

    // MARK: - Small value types

    func testAppTileDefaultsToNoDisplayedWidget() {
        XCTAssertNil(AppTile(bundleIdentifier: "a", displayName: "A").displayedWidget)
    }

    func testAppFolderTileDefaultsAndBundleIdentifiers() {
        let apps = [AppTile(bundleIdentifier: "a", displayName: "A"), AppTile(bundleIdentifier: "b", displayName: "B")]
        let folder = AppFolderTile(identifier: "f", displayName: "F", apps: apps)
        XCTAssertEqual(folder.displayMode, .grid)
        XCTAssertEqual(folder.contentViewMode, .grid)
        XCTAssertEqual(folder.bundleIdentifiers, ["a", "b"])
    }

    func testEmptyAppFolderHasNoBundleIdentifiers() {
        XCTAssertEqual(AppFolderTile(identifier: "f", displayName: "F", apps: []).bundleIdentifiers, [])
    }

    func testLaunchpadTileDefaultTitle() {
        XCTAssertEqual(LaunchpadTile(identifier: "l").title, "Launchpad")
        XCTAssertEqual(LaunchpadTile.spotlightBundleIdentifier, "com.apple.Spotlight")
    }

    func testStartMenuTileDefaultTitleAndIconBundle() {
        XCTAssertEqual(StartMenuTile(identifier: "s").title, "Start")
        XCTAssertEqual(StartMenuTile.iconBundleIdentifier, "gt.quintero.Wharf")
    }

    func testFolderTileDefaults() {
        let tile = FolderTile(url: URL(fileURLWithPath: "/tmp"), displayName: "tmp", displayMode: .folder)
        XCTAssertEqual(tile.contentViewMode, .grid)
        XCTAssertEqual(tile.sortMode, .dateAdded)
    }

    func testWidgetExpansionExtentStandardIsThreeByThree() {
        XCTAssertEqual(WidgetExpansionExtent.standard, WidgetExpansionExtent(widthTiles: 3, heightTiles: 3))
    }

    // MARK: - TileSpan

    func testTileSpanRawValues() {
        XCTAssertEqual(TileSpan.allCases.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertEqual(TileSpan.four.id, 4)
    }

    func testTileSpanRejectsOutOfRangeRawValues() {
        for raw in [-1, 0, 5, 100, Int.max, Int.min] {
            XCTAssertNil(TileSpan(rawValue: raw), "raw \(raw)")
        }
    }

    func testTileSpanCodableRoundTrip() throws {
        for span in TileSpan.allCases {
            let data = try JSONEncoder().encode([span])
            XCTAssertEqual(try JSONDecoder().decode([TileSpan].self, from: data), [span])
        }
    }

    func testTileSpanDecodeOfInvalidValueThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode([TileSpan].self, from: Data("[9]".utf8)))
    }

    // MARK: - WidgetKind

    func testBuiltInCasesAreUniqueAndExcludeExternal() {
        XCTAssertEqual(Set(WidgetKind.builtInCases).count, WidgetKind.builtInCases.count)
        for kind in WidgetKind.builtInCases {
            if case .external = kind { XCTFail("built-in list contains an external kind") }
        }
    }

    func testRawValueRoundTripForEveryBuiltInKind() {
        for kind in WidgetKind.builtInCases {
            XCTAssertEqual(WidgetKind(rawValue: kind.rawValue), kind, kind.rawValue)
            XCTAssertEqual(kind.id, kind.rawValue)
        }
    }

    func testBuiltInRawValuesAreUnique() {
        let raws = WidgetKind.builtInCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    func testExternalRawValueRoundTrip() {
        let kind = WidgetKind.external("com.example.MyWidget")
        XCTAssertEqual(kind.rawValue, "external:com.example.MyWidget")
        XCTAssertEqual(WidgetKind(rawValue: "external:com.example.MyWidget"), kind)
    }

    func testExternalWithEmptyIdentifierIsRejected() {
        XCTAssertNil(WidgetKind(rawValue: "external:"))
    }

    func testExternalIdentifierMayContainColons() {
        XCTAssertEqual(WidgetKind(rawValue: "external:a:b"), .external("a:b"))
    }

    func testUnknownRawValuesAreRejected() {
        for raw in ["", " ", "Calendar", "CALENDAR", "calendar ", "nope", "external", "EXTERNAL:x"] {
            XCTAssertNil(WidgetKind(rawValue: raw), "raw '\(raw)'")
        }
    }

    func testWidgetKindCodableRoundTripIncludingExternal() throws {
        let kinds = WidgetKind.builtInCases + [.external("x.y")]
        let data = try JSONEncoder().encode(kinds)
        XCTAssertEqual(try JSONDecoder().decode([WidgetKind].self, from: data), kinds)
    }

    func testWidgetKindEncodesAsPlainString() throws {
        let data = try JSONEncoder().encode([WidgetKind.weather])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"weather\"]")
    }

    func testWidgetKindDecodeOfUnknownStringThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode([WidgetKind].self, from: Data("[\"bogus\"]".utf8)))
    }

    func testWidgetKindDecodeOfNonStringThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode([WidgetKind].self, from: Data("[7]".utf8)))
    }

    func testCalendarDateIsTheOnlySingleSpanBuiltIn() {
        for kind in WidgetKind.builtInCases {
            let expected: [TileSpan] = kind == .calendarDate ? [.one] : TileSpan.allCases
            XCTAssertEqual(kind.supportedSpans, expected, kind.rawValue)
        }
    }

    func testNowPlayingHasTheWideExpansionExtent() {
        XCTAssertEqual(WidgetKind.nowPlaying.expansionExtent, WidgetExpansionExtent(widthTiles: 5, heightTiles: 2))
    }

    func testOtherBuiltInsUseTheStandardExpansionExtent() {
        for kind in WidgetKind.builtInCases where kind != .nowPlaying {
            XCTAssertEqual(kind.expansionExtent, .standard, kind.rawValue)
        }
    }

    func testExpandableTable() {
        let expandable: Set<WidgetKind> = [.calendar, .reminders, .batteries, .systemStatus, .nowPlaying, .weather, .photoFrame]
        for kind in WidgetKind.builtInCases {
            XCTAssertEqual(kind.isExpandable, expandable.contains(kind), kind.rawValue)
        }
    }

    func testUnregisteredExternalWidgetFallsBackToSafeDefaults() {
        let kind = WidgetKind.external("test.unregistered.\(UUID().uuidString)")
        XCTAssertEqual(kind.supportedSpans, TileSpan.allCases)
        XCTAssertEqual(kind.expansionExtent, .standard)
        XCTAssertFalse(kind.isExpandable)
    }

    func testUnregisteredExternalWidgetTitleFallsBackToIdentifier() {
        let id = "test.unregistered.\(UUID().uuidString)"
        XCTAssertEqual(WidgetKind.external(id).title, id)
    }

    func testBuiltInTitlesAreNonEmpty() {
        for kind in WidgetKind.builtInCases {
            XCTAssertFalse(kind.title.isEmpty, kind.rawValue)
        }
    }

    func testCatalogBuiltInRegistrationsUseOnlyKnownKinds() {
        for registration in WidgetCatalog.builtInRegistrations {
            XCTAssertTrue(WidgetKind.builtInCases.contains(registration.kind), registration.id)
            XCTAssertTrue(registration.kind.supportedSpans.contains(registration.defaultSpan), registration.id)
        }
    }

    func testCatalogRegistrationIDsAreUnique() {
        let ids = WidgetCatalog.builtInRegistrations.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testRegistrationMakeTileUsesDefaultSpanAndOverride() {
        let registration = WidgetCatalog.weather
        XCTAssertEqual(registration.makeTile().span, registration.defaultSpan)
        XCTAssertEqual(registration.makeTile(span: .one).span, .one)
        XCTAssertEqual(registration.makeTile().identifier, registration.id)
        XCTAssertEqual(registration.makeTile().ownerBundleIdentifier, registration.ownerBundleIdentifier)
    }

    // MARK: - WidgetTile / SmartStackTile / placements

    private func widget(_ kind: WidgetKind, owner: String = "o", span: TileSpan) -> WidgetTile {
        WidgetTile(identifier: "\(owner):\(kind.rawValue)", title: kind.rawValue, kind: kind, ownerBundleIdentifier: owner, span: span)
    }

    func testEffectiveSpanKeepsASupportedSpan() {
        XCTAssertEqual(widget(.calendar, span: .two).effectiveSpan, .two)
        XCTAssertEqual(widget(.calendar, span: .four).effectiveSpan, .four)
    }

    func testEffectiveSpanClampsUnsupportedSpanToLastSupported() {
        XCTAssertEqual(widget(.calendarDate, span: .three).effectiveSpan, .one)
        XCTAssertEqual(widget(.calendarDate, span: .four).effectiveSpan, .one)
    }

    func testWidgetTileSettingsDefaultToEmpty() {
        XCTAssertTrue(widget(.clock, span: .one).settings.isEmpty)
    }

    func testSmartStackOwnersAreSortedAndDeduplicated() {
        let stack = SmartStackTile(
            identifier: "s",
            title: "Stack",
            widgets: [
                widget(.weather, owner: "z", span: .three),
                widget(.calendar, owner: "a", span: .three),
                widget(.reminders, owner: "z", span: .three),
            ],
            span: .three
        )
        XCTAssertEqual(stack.allWidgetOwnerBundleIdentifiers, ["a", "z"])
    }

    func testEmptySmartStackHasNoOwners() {
        let stack = SmartStackTile(identifier: "s", title: "Stack", widgets: [], span: .one)
        XCTAssertEqual(stack.allWidgetOwnerBundleIdentifiers, [])
    }

    func testWidgetPlacementIDAndCodable() throws {
        let placement = WidgetPlacement(kind: .weather, ownerBundleIdentifier: "owner", span: .two)
        XCTAssertEqual(placement.id, "owner:weather")
        let data = try JSONEncoder().encode(placement)
        XCTAssertEqual(try JSONDecoder().decode(WidgetPlacement.self, from: data), placement)
    }

    func testAppWidgetDisplayIDAndCodable() throws {
        let display = AppWidgetDisplay(bundleIdentifier: "com.apple.Music", kind: .nowPlaying, span: .three)
        XCTAssertEqual(display.id, "com.apple.Music")
        let data = try JSONEncoder().encode(display)
        XCTAssertEqual(try JSONDecoder().decode(AppWidgetDisplay.self, from: data), display)
    }

    func testWidgetPlacementDecodeWithBadKindThrows() {
        let json = #"{"kind":"bogus","ownerBundleIdentifier":"o","span":1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetPlacement.self, from: Data(json.utf8)))
    }

    // MARK: - PinnedTileItem factories

    func testAppItemIDIsDeterministic() {
        XCTAssertEqual(PinnedTileItem.app(bundleIdentifier: "com.x").id, "app:com.x")
        XCTAssertEqual(PinnedTileItem.app(bundleIdentifier: "com.x"), PinnedTileItem.app(bundleIdentifier: "com.x"))
        XCTAssertEqual(PinnedTileItem.app(bundleIdentifier: "com.x").kind, .app)
        XCTAssertEqual(PinnedTileItem.app(bundleIdentifier: "com.x").bundleIdentifier, "com.x")
    }

    func testGeneratedItemsGetDistinctCustomIDs() {
        let makers: [() -> PinnedTileItem] = [
            { .spacer() },
            { .flexibleSpacer() },
            { .divider() },
            { .smartStack() },
            { .launchpad() },
            { .startMenu() },
            { .widget(kind: .clock, ownerBundleIdentifier: "o") },
            { .appFolder(bundleIdentifiers: ["a", "b"]) },
        ]
        var seen: Set<String> = []
        for make in makers {
            let first = make()
            let second = make()
            XCTAssertTrue(first.id.hasPrefix("custom:"), first.id)
            XCTAssertNotNil(UUID(uuidString: String(first.id.dropFirst("custom:".count))))
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertTrue(seen.insert(first.id).inserted)
            XCTAssertTrue(seen.insert(second.id).inserted)
        }
    }

    func testPinnedItemKinds() {
        XCTAssertEqual(PinnedTileItem.spacer().kind, .spacer)
        XCTAssertEqual(PinnedTileItem.flexibleSpacer().kind, .flexibleSpacer)
        XCTAssertEqual(PinnedTileItem.divider().kind, .divider)
        XCTAssertEqual(PinnedTileItem.smartStack().kind, .smartStack)
        XCTAssertEqual(PinnedTileItem.launchpad().kind, .launchpad)
        XCTAssertEqual(PinnedTileItem.startMenu().kind, .startMenu)
        XCTAssertEqual(PinnedTileItem.widget(kind: .clock, ownerBundleIdentifier: "o").kind, .widget)
        XCTAssertEqual(PinnedTileItem.appFolder(bundleIdentifiers: []).kind, .appFolder)
    }

    func testWidgetItemDefaultsToSpanThree() {
        let item = PinnedTileItem.widget(kind: .weather, ownerBundleIdentifier: "o")
        XCTAssertEqual(item.widgetSpan, .three)
        XCTAssertEqual(item.widgetKind, .weather)
        XCTAssertEqual(item.widgetOwnerBundleIdentifier, "o")
    }

    func testAppFolderItemDefaults() {
        let item = PinnedTileItem.appFolder(bundleIdentifiers: ["a", "b"])
        XCTAssertEqual(item.folderDisplayName, "Folder")
        XCTAssertEqual(item.appFolderDisplayMode, .grid)
        XCTAssertEqual(item.folderContentViewMode, .grid)
        XCTAssertEqual(item.folderBundleIdentifiers, ["a", "b"])
    }

    func testSmartStackItemDefaultsToTheCatalogHiddenList() {
        XCTAssertEqual(
            PinnedTileItem.smartStack().hiddenWidgetOwnerBundleIdentifiers,
            WidgetCatalog.defaultHiddenSmartStackOwnerBundleIdentifiers
        )
    }

    func testPinnedItemCodableRoundTrip() throws {
        let items: [PinnedTileItem] = [
            .app(bundleIdentifier: "com.x"),
            .appFolder(id: "custom:fixed", displayName: "Dev", bundleIdentifiers: ["a", "b"], displayMode: .stack, contentViewMode: .list),
            .widget(kind: .external("e.id"), ownerBundleIdentifier: "e.id", span: .four),
            .spacer(),
            .smartStack(hiddenWidgetOwnerBundleIdentifiers: ["h"]),
        ]
        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([PinnedTileItem].self, from: data), items)
    }

    func testPinnedItemDecodesWithoutOptionalWidgetSettings() throws {
        let json = """
        {"id":"app:x","kind":"app","bundleIdentifier":"x","folderBundleIdentifiers":[],"hiddenWidgetOwnerBundleIdentifiers":[]}
        """
        let item = try JSONDecoder().decode(PinnedTileItem.self, from: Data(json.utf8))
        XCTAssertEqual(item, .app(bundleIdentifier: "x"))
        XCTAssertNil(item.widgetSettings)
    }

    func testPinnedItemDecodeWithUnknownKindThrows() {
        let json = """
        {"id":"a","kind":"hologram","folderBundleIdentifiers":[],"hiddenWidgetOwnerBundleIdentifiers":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PinnedTileItem.self, from: Data(json.utf8)))
    }

    // MARK: - TrailingTileItem factories

    func testTrashItemHasAConstantID() {
        XCTAssertEqual(TrailingTileItem.trash().id, "trash")
        XCTAssertEqual(TrailingTileItem.trash(), TrailingTileItem.trash())
        XCTAssertEqual(TrailingTileItem.trash().kind, .trash)
    }

    func testSystemFolderItemIDDerivesFromSourceTileID() {
        let item = TrailingTileItem.folder(sourceTileID: "12345")
        XCTAssertEqual(item.id, "folder:12345")
        XCTAssertEqual(item.sourceTileID, "12345")
        XCTAssertNil(item.folderURL)
    }

    func testCustomFolderItemGetsDistinctPrefixedIDs() {
        let url = URL(fileURLWithPath: "/tmp")
        let a = TrailingTileItem.folder(url: url, displayName: "tmp")
        let b = TrailingTileItem.folder(url: url, displayName: "tmp")
        XCTAssertTrue(a.id.hasPrefix("custom-folder:"))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.folderURL, url)
    }

    func testFolderItemEffectiveDefaults() {
        let bare = TrailingTileItem(id: "x", kind: .folder)
        XCTAssertEqual(bare.effectiveFolderDisplayMode, .contents)
        XCTAssertEqual(bare.effectiveFolderContentViewMode, .grid)
        XCTAssertEqual(bare.effectiveFolderSortMode, .dateAdded)
    }

    func testFolderItemEffectiveValuesFollowExplicitSettings() {
        let item = TrailingTileItem(
            id: "x",
            kind: .folder,
            folderDisplayMode: .folder,
            folderContentViewMode: .list,
            folderSortMode: .name
        )
        XCTAssertEqual(item.effectiveFolderDisplayMode, .folder)
        XCTAssertEqual(item.effectiveFolderContentViewMode, .list)
        XCTAssertEqual(item.effectiveFolderSortMode, .name)
    }

    func testTrailingItemCodableRoundTrip() throws {
        let items: [TrailingTileItem] = [
            .trash(),
            .folder(sourceTileID: "9", displayMode: .folder, contentViewMode: .fan, sortMode: .kind),
            .folder(id: "custom-folder:fixed", url: URL(fileURLWithPath: "/Users/Shared"), displayName: "Shared"),
            .widget(kind: .clock, ownerBundleIdentifier: "o"),
        ]
        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([TrailingTileItem].self, from: data), items)
    }
}
