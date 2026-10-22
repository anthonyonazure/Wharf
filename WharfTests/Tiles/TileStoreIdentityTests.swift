import XCTest
@testable import Wharf

/// Identity and conversion rules in `TileStore`: how a tile maps to a persisted
/// pinned/trailing item and back, which ids each side derives, and how the
/// system Dock's items merge into Wharf's own pinned list.
@MainActor
final class TileStoreIdentityTests: XCTestCase {
    private func app(_ bundleID: String, name: String = "App") -> Tile {
        Tile(id: "t-\(bundleID)", content: .app(AppTile(bundleIdentifier: bundleID, displayName: name)))
    }

    private func appFolder(id: String = "f", bundleIDs: [String]) -> Tile {
        let apps = bundleIDs.map { AppTile(bundleIdentifier: $0, displayName: $0) }
        return Tile(id: "t-\(id)", content: .appFolder(AppFolderTile(
            identifier: id,
            displayName: "Folder \(id)",
            apps: apps,
            displayMode: .stack,
            contentViewMode: .list
        )))
    }

    private func widgetTile(_ kind: WidgetKind = .clock) -> Tile {
        Tile(id: "w", content: .widget(WidgetTile(
            identifier: "o:\(kind.rawValue)", title: "W", kind: kind, ownerBundleIdentifier: "o", span: .one
        )))
    }

    // MARK: - ids

    func testPinnedAndTrailingTileIDsArePrefixedItemIDs() {
        XCTAssertEqual(TileStore.pinnedTileID(for: .app(bundleIdentifier: "com.x")), "pinned:app:com.x")
        XCTAssertEqual(TileStore.pinnedTileID(for: .appFolder(id: "custom:1", bundleIdentifiers: ["a", "b"])), "pinned:custom:1")
        XCTAssertEqual(TileStore.trailingTileID(for: .trash()), "trailing:trash")
        XCTAssertEqual(TileStore.trailingTileID(for: .folder(sourceTileID: "9")), "trailing:folder:9")
    }

    func testPinnedAndTrailingNamespacesNeverCollide() {
        XCTAssertNotEqual(
            TileStore.pinnedTileID(for: PinnedTileItem(
                id: "trash", kind: .spacer, bundleIdentifier: nil, folderDisplayName: nil,
                folderBundleIdentifiers: [], appFolderDisplayMode: nil, folderContentViewMode: nil,
                widgetKind: nil, widgetOwnerBundleIdentifier: nil, widgetSpan: nil,
                hiddenWidgetOwnerBundleIdentifiers: []
            )),
            TileStore.trailingTileID(for: .trash())
        )
    }

    func testFinderBundleIdentifier() {
        XCTAssertEqual(TileStore.finderBundleID, "com.apple.finder")
    }

    // MARK: - isFinder / isTrash

    func testIsFinder() {
        XCTAssertTrue(TileStore.isFinder(app("com.apple.finder")))
        XCTAssertFalse(TileStore.isFinder(app("com.apple.Finder")))
        XCTAssertFalse(TileStore.isFinder(app("")))
        XCTAssertFalse(TileStore.isFinder(Tile(id: "x", content: .trash)))
        XCTAssertFalse(TileStore.isFinder(appFolder(bundleIDs: ["com.apple.finder", "b"])))
    }

    func testIsTrash() {
        XCTAssertTrue(TileStore.isTrash(Tile(id: "x", content: .trash)))
        XCTAssertFalse(TileStore.isTrash(Tile(id: "x", content: .spacer)))
        XCTAssertFalse(TileStore.isTrash(app("com.apple.finder")))
    }

    // MARK: - bundleIdentifiers(in:)

    func testBundleIdentifiersCollectsAppsAndFolderMembers() {
        let tiles = [app("a"), appFolder(bundleIDs: ["b", "c"]), widgetTile(), Tile(id: "s", content: .spacer)]
        XCTAssertEqual(TileStore.bundleIdentifiers(in: tiles), ["a", "b", "c"])
    }

    func testBundleIdentifiersSkipsEmptyAppIDs() {
        XCTAssertEqual(TileStore.bundleIdentifiers(in: [app("")]), [])
    }

    func testBundleIdentifiersDeduplicates() {
        XCTAssertEqual(TileStore.bundleIdentifiers(in: [app("a"), app("a"), appFolder(bundleIDs: ["a", "b"])]), ["a", "b"])
    }

    func testBundleIdentifiersOfEmptyList() {
        XCTAssertEqual(TileStore.bundleIdentifiers(in: []), [])
    }

    // MARK: - normalizedApplicationName

    func testNormalizedApplicationName() {
        let cases: [(String, String)] = [
            ("Safari.app", "safari"),
            ("Safari.APP", "safari"),
            ("  Safari.app  ", "safari"),
            ("Safari .app", "safari"),
            ("Safari", "safari"),
            ("Caf\u{00E9}", "cafe"),
            ("Cafe\u{0301}.app", "cafe"),
            ("\u{00C5}ngstr\u{00F6}m", "angstrom"),
            ("Foo.app.app", "foo"),
            (".app", ""),
            ("", ""),
            ("   ", ""),
            ("app", "app"),
            ("\tNotes\n", "notes"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TileStore.normalizedApplicationName(input), expected, "input '\(input)'")
        }
    }

    func testNormalizedApplicationNameOnlyStripsATrailingDotApp() {
        XCTAssertEqual(TileStore.normalizedApplicationName("My.application"), "my.application")
        XCTAssertEqual(TileStore.normalizedApplicationName("My.app.Thing"), "my.app.thing")
        XCTAssertEqual(TileStore.normalizedApplicationName("My.application.app"), "my.application")
    }

    func testNormalizedApplicationNameIsIdempotent() {
        for name in ["Safari.app", "Caf\u{00E9}", " X ", "Foo.app.app"] {
            let once = TileStore.normalizedApplicationName(name)
            XCTAssertEqual(TileStore.normalizedApplicationName(once), once)
        }
    }

    // MARK: - pinnedItem(from:)

    func testPinnedItemFromApp() {
        XCTAssertEqual(TileStore.pinnedItem(from: app("com.x")), .app(bundleIdentifier: "com.x"))
    }

    func testPinnedItemFromAppWithEmptyBundleIDIsNil() {
        XCTAssertNil(TileStore.pinnedItem(from: app("")))
    }

    func testPinnedItemFromAppFolderKeepsIdentityAndModes() {
        let item = TileStore.pinnedItem(from: appFolder(id: "custom:z", bundleIDs: ["a", "b", "c"]))
        XCTAssertEqual(item?.kind, .appFolder)
        XCTAssertEqual(item?.id, "custom:z")
        XCTAssertEqual(item?.folderBundleIdentifiers, ["a", "b", "c"])
        XCTAssertEqual(item?.appFolderDisplayMode, .stack)
        XCTAssertEqual(item?.folderContentViewMode, .list)
        XCTAssertEqual(item?.folderDisplayName, "Folder custom:z")
    }

    func testPinnedItemFromAppFolderBelowTwoAppsIsNil() {
        XCTAssertNil(TileStore.pinnedItem(from: appFolder(bundleIDs: [])))
        XCTAssertNil(TileStore.pinnedItem(from: appFolder(bundleIDs: ["only"])))
    }

    func testPinnedItemFromLaunchpadAndStartMenu() {
        let launchpad = Tile(id: "lp", content: .launchpad(LaunchpadTile(identifier: "custom:lp")))
        let start = Tile(id: "st", content: .startMenu(StartMenuTile(identifier: "custom:st")))
        XCTAssertEqual(TileStore.pinnedItem(from: launchpad), .launchpad(id: "custom:lp"))
        XCTAssertEqual(TileStore.pinnedItem(from: start), .startMenu(id: "custom:st"))
    }

    func testPinnedItemFromStructuralTilesUsesTheTileID() {
        let expectations: [(TileContent, PinnedTileItemKind)] = [
            (.spacer, .spacer), (.flexibleSpacer, .flexibleSpacer), (.divider, .divider),
        ]
        for (content, kind) in expectations {
            let item = TileStore.pinnedItem(from: Tile(id: "tile-id", content: content))
            XCTAssertEqual(item?.id, "tile-id")
            XCTAssertEqual(item?.kind, kind)
            XCTAssertNil(item?.bundleIdentifier)
            XCTAssertEqual(item?.folderBundleIdentifiers, [])
        }
    }

    func testPinnedItemFromNonPinnableContentIsNil() {
        let stack = SmartStackTile(identifier: "s", title: "S", widgets: [], span: .one)
        let tiles = [
            widgetTile(),
            Tile(id: "s", content: .smartStack(stack)),
            Tile(id: "t", content: .trash),
            Tile(id: "f", content: .folder(FolderTile(url: URL(fileURLWithPath: "/tmp"), displayName: "tmp", displayMode: .folder))),
        ]
        for tile in tiles {
            XCTAssertNil(TileStore.pinnedItem(from: tile), "\(tile.content)")
        }
    }

    // MARK: - trailingItem(from:)

    func testTrailingItemFromFolderKeepsModes() {
        let folder = FolderTile(
            url: URL(fileURLWithPath: "/tmp"), displayName: "tmp", displayMode: .folder, contentViewMode: .fan
        )
        let item = TileStore.trailingItem(from: Tile(id: "12", content: .folder(folder)))
        XCTAssertEqual(item?.kind, .folder)
        XCTAssertEqual(item?.id, "folder:12")
        XCTAssertEqual(item?.sourceTileID, "12")
        XCTAssertEqual(item?.folderDisplayMode, .folder)
        XCTAssertEqual(item?.folderContentViewMode, .fan)
    }

    func testTrailingItemFromTrash() {
        XCTAssertEqual(TileStore.trailingItem(from: Tile(id: "x", content: .trash)), .trash())
    }

    func testTrailingItemFromEverythingElseIsNil() {
        let tiles = [
            app("a"),
            appFolder(bundleIDs: ["a", "b"]),
            widgetTile(),
            Tile(id: "s", content: .spacer),
            Tile(id: "s", content: .flexibleSpacer),
            Tile(id: "s", content: .divider),
            Tile(id: "l", content: .launchpad(LaunchpadTile(identifier: "l"))),
            Tile(id: "m", content: .startMenu(StartMenuTile(identifier: "m"))),
        ]
        for tile in tiles {
            XCTAssertNil(TileStore.trailingItem(from: tile), "\(tile.content)")
        }
    }

    // MARK: - matchesImportedPinnedItem

    func testAppItemsMatchByBundleIdentifier() {
        XCTAssertTrue(TileStore.matchesImportedPinnedItem(.app(bundleIdentifier: "a"), .app(bundleIdentifier: "a")))
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(.app(bundleIdentifier: "a"), .app(bundleIdentifier: "b")))
    }

    func testDifferentKindsNeverMatch() {
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(.app(bundleIdentifier: "a"), .launchpad(id: "app:a")))
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(.spacer(), .divider()))
    }

    func testIDKindsMatchByID() {
        XCTAssertTrue(TileStore.matchesImportedPinnedItem(.launchpad(id: "x"), .launchpad(id: "x")))
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(.launchpad(id: "x"), .launchpad(id: "y")))
        XCTAssertTrue(TileStore.matchesImportedPinnedItem(.startMenu(id: "x"), .startMenu(id: "x")))
        let spacerA = PinnedTileItem.spacer()
        XCTAssertTrue(TileStore.matchesImportedPinnedItem(spacerA, spacerA))
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(spacerA, .spacer()))
        let folder = PinnedTileItem.appFolder(id: "custom:f", bundleIdentifiers: ["a", "b"])
        XCTAssertTrue(TileStore.matchesImportedPinnedItem(folder, folder))
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(folder, .appFolder(id: "custom:g", bundleIdentifiers: ["a", "b"])))
    }

    func testWidgetsAndSmartStacksNeverMatchAnImport() {
        let widget = PinnedTileItem.widget(kind: .clock, ownerBundleIdentifier: "o")
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(widget, widget))
        let stack = PinnedTileItem.smartStack()
        XCTAssertFalse(TileStore.matchesImportedPinnedItem(stack, stack))
    }

    // MARK: - reordered

    func testReorderedSkipsUnknownIDsAndHandsOutSharedIDsInOrder() {
        let result = TileStore.reordered(["x1", "x2", "y"], by: ["y", "x", "x", "ghost"], site: "test") {
            String($0.prefix(1))
        }
        XCTAssertEqual(result, ["y", "x1", "x2"])
    }

    // MARK: - pinnedItemAdditions (system Dock merge)

    func testAdditionsExcludeFinderAndAlreadyPinnedApps() {
        let existing = [PinnedTileItem.app(bundleIdentifier: "a")]
        let refreshed = [app("com.apple.finder"), app("a"), app("b")]
        XCTAssertEqual(
            TileStore.pinnedItemAdditions(existing: existing, refreshed: refreshed),
            [.app(bundleIdentifier: "b")]
        )
    }

    func testAdditionsIgnoreUnpinnableTiles() {
        let refreshed = [widgetTile(), Tile(id: "t", content: .trash), app("")]
        XCTAssertEqual(TileStore.pinnedItemAdditions(existing: [], refreshed: refreshed), [])
    }

    func testAdditionsKeepSpacersFromTheSystemDock() {
        let refreshed = [Tile(id: "99", content: .spacer)]
        let additions = TileStore.pinnedItemAdditions(existing: [], refreshed: refreshed)
        XCTAssertEqual(additions.map(\.id), ["99"])
        XCTAssertEqual(additions.first?.kind, .spacer)
    }

    func testAdditionsAreEmptyWhenEverythingIsAlreadyPresent() {
        let existing = [PinnedTileItem.app(bundleIdentifier: "a"), .app(bundleIdentifier: "b")]
        XCTAssertEqual(TileStore.pinnedItemAdditions(existing: existing, refreshed: [app("a"), app("b")]), [])
    }

    func testAdditionsFromEmptyDockAreEmpty() {
        XCTAssertEqual(TileStore.pinnedItemAdditions(existing: [.app(bundleIdentifier: "a")], refreshed: []), [])
    }

    func testAdditionsWithTheSameAppTwiceInTheDockStayUnique() {
        // A hostile or sloppy plist can list an app twice. Both copies would
        // otherwise be appended with the same item id ("app:b"), producing two
        // pinned tiles with one identity.
        let additions = TileStore.pinnedItemAdditions(existing: [], refreshed: [app("b"), app("b")])
        XCTAssertEqual(additions, [.app(bundleIdentifier: "b")])
        XCTAssertEqual(Set(additions.map(\.id)).count, additions.count)
    }

    func testAdditionsWithSpacersSharingAGuidStayUnique() {
        let refreshed = [Tile(id: "5", content: .spacer), Tile(id: "5", content: .spacer)]
        let additions = TileStore.pinnedItemAdditions(existing: [], refreshed: refreshed)
        XCTAssertEqual(additions.map(\.id), ["5"])
        XCTAssertEqual(Set(additions.map(\.id)).count, additions.count)
    }

    // MARK: - makePinnedTile / makeWidgetTile

    func testMakePinnedTileFromAppTileUsesItemIDAndKeepsDisplayName() {
        let tile = TileStore.makePinnedTile(from: app("old.id", name: "Display"), item: .app(bundleIdentifier: "new.id"))
        XCTAssertEqual(tile?.id, "pinned:app:new.id")
        guard case .app(let result)? = tile?.content else { return XCTFail("expected app") }
        XCTAssertEqual(result.bundleIdentifier, "new.id")
        XCTAssertEqual(result.displayName, "Display")
    }

    func testMakePinnedTileFromNonAppIsNil() {
        XCTAssertNil(TileStore.makePinnedTile(from: Tile(id: "s", content: .spacer), item: .app(bundleIdentifier: "x")))
    }

    func testMakePinnedTileFromAppWithItemLackingBundleIDGetsEmptyID() {
        let tile = TileStore.makePinnedTile(from: app("a"), item: .spacer())
        guard case .app(let result)? = tile?.content else { return XCTFail("expected app") }
        XCTAssertEqual(result.bundleIdentifier, "")
    }

    func testMakePinnedTileByBundleIDRefusesEmptyAndUnknownIDs() {
        XCTAssertNil(TileStore.makePinnedTile(bundleIdentifier: "", item: .app(bundleIdentifier: "")))
        XCTAssertNil(TileStore.makePinnedTile(bundleIdentifier: "no.such.app.\(UUID().uuidString)", item: .app(bundleIdentifier: "x")))
    }

    func testMakeWidgetTile() {
        let tile = TileStore.makeWidgetTile(kind: .weather, ownerBundleIdentifier: "owner", span: .two)
        XCTAssertEqual(tile.identifier, "owner:weather")
        XCTAssertEqual(tile.kind, .weather)
        XCTAssertEqual(tile.span, .two)
        XCTAssertTrue(tile.settings.isEmpty)
    }

    // MARK: - Agreement between TileStore and DockEditorService ids

    func testEditorAndStoreDeriveTheSameIDForEveryEntryShape() {
        let editor = DockEditorService(dockPlistURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).plist"))
        let entries: [[String: Any]] = [
            [:],
            ["tile-type": "spacer-tile"],
            ["tile-type": "spacer-tile", "GUID": NSNumber(value: 12)],
            ["tile-type": "file-tile", "GUID": NSNumber(value: UInt64.max), "tile-data": ["bundle-identifier": "a"]],
            ["tile-type": "file-tile", "GUID": NSNumber(value: -3), "tile-data": [:] as [String: Any]],
            ["tile-type": "file-tile", "GUID": "string-guid", "tile-data": ["bundle-identifier": "a:b", "file-label": "x:y"]],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "a", "file-data": ["_CFURLString": "file:///A.app/"], "file-label": "A"]],
            ["tile-type": "directory-tile", "tile-data": ["file-data": ["_CFURLString": "file:///d/"], "file-label": "D"]],
            ["tile-type": "url-tile", "tile-data": ["label": "L"]],
            ["tile-type": 5, "tile-data": 6],
        ]
        for (index, entry) in entries.enumerated() {
            let storeID = (entry["GUID"] as? NSNumber)?.stringValue
                ?? TileStore.fallbackTileID(for: entry, at: index, section: "persistent-apps")
            XCTAssertEqual(editor.pinnedItemID(in: entry, at: index), storeID, "entry \(index)")
        }
    }
}
