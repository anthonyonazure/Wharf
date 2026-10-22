import XCTest
@testable import Wharf

/// Pinned items, trailing items, widget placements, app-widget displays, and the
/// hidden-app list: the "tile store" fields that are also mirrored to profiles.
///
/// `makePrefs()` switches profile mirroring off, so assigning these properties
/// never reaches `ProfileService.shared` (and through it the real defaults).
final class TileStoreTests: DockyPreferencesTestCase {

    // MARK: normalizedBundleIdentifiers

    func testNormalizeEmptyInput() {
        XCTAssertEqual(DockyPreferences.normalizedBundleIdentifiers([]), [])
    }

    func testNormalizeDropsEmptyStrings() {
        XCTAssertEqual(DockyPreferences.normalizedBundleIdentifiers(["", "a.b", ""]), ["a.b"])
    }

    func testNormalizeDeduplicatesExactMatches() {
        XCTAssertEqual(DockyPreferences.normalizedBundleIdentifiers(["a", "a", "a", "b", "b"]), ["a", "b"])
    }

    func testNormalizeSortsCaseInsensitively() {
        XCTAssertEqual(
            DockyPreferences.normalizedBundleIdentifiers(["com.zeta", "com.alpha", "com.Mu", "com.beta"]),
            ["com.alpha", "com.beta", "com.Mu", "com.zeta"]
        )
    }

    func testNormalizeKeepsCaseVariantsAsSeparateEntries() {
        let result = DockyPreferences.normalizedBundleIdentifiers(["com.App", "com.app"])
        XCTAssertEqual(Set(result), ["com.App", "com.app"])
    }

    /// Whitespace is not trimmed: a padded identifier is a different identifier.
    func testNormalizeDoesNotTrimWhitespace() {
        let result = DockyPreferences.normalizedBundleIdentifiers([" a", "a", "a ", "  "])
        XCTAssertEqual(Set(result), [" a", "a", "a ", "  "])
    }

    func testNormalizeIsIdempotent() {
        let once = DockyPreferences.normalizedBundleIdentifiers(["b", "", "a", "b", "C"])
        XCTAssertEqual(DockyPreferences.normalizedBundleIdentifiers(once), once)
    }

    func testNormalizeHandlesTenThousandDuplicates() {
        let ids = (0..<10_000).map { "com.app.\($0 % 100)" }
        XCTAssertEqual(DockyPreferences.normalizedBundleIdentifiers(ids).count, 100)
    }

    func testNormalizeHandlesUnicodeAndLongStrings() {
        let long = String(repeating: "x", count: 50_000)
        let result = DockyPreferences.normalizedBundleIdentifiers(["\u{1F642}", long, "\u{00E9}", "e\u{0301}"])
        // Swift treats canonically equivalent strings as equal, so the two "e acute" forms collapse.
        XCTAssertEqual(result.count, 3)
    }

    // MARK: hiddenAppBundleIdentifiers

    func testHiddenAppsDefaultToEmpty() {
        XCTAssertEqual(makePrefs().hiddenAppBundleIdentifiers, [])
    }

    func testHiddenAppsAreNormalizedWhenLoaded() {
        defaults.set(["b.app", "", "a.app", "b.app"], forKey: PrefKeys.hiddenAppBundleIdentifiers)
        XCTAssertEqual(makePrefs().hiddenAppBundleIdentifiers, ["a.app", "b.app"])
    }

    func testHiddenAppsWrongTypeIsEmpty() {
        for wrong in ["a.app", [1, 2], ["k": "v"], Data([1])] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.hiddenAppBundleIdentifiers)
            XCTAssertEqual(makePrefs().hiddenAppBundleIdentifiers, [], "\(type(of: wrong))")
        }
    }

    func testHiddenAppsSetterNormalizesAndPersists() {
        let prefs = makePrefs()
        prefs.hiddenAppBundleIdentifiers = ["z.app", "", "a.app", "z.app"]
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, ["a.app", "z.app"])
        XCTAssertEqual(defaults.stringArray(forKey: PrefKeys.hiddenAppBundleIdentifiers), ["a.app", "z.app"])
        XCTAssertEqual(reload().hiddenAppBundleIdentifiers, ["a.app", "z.app"])
    }

    func testHiddenAppsSetterWithEmptyStringsOnlyEndsEmpty() {
        let prefs = makePrefs()
        prefs.hiddenAppBundleIdentifiers = ["a.app"]
        prefs.hiddenAppBundleIdentifiers = ["", ""]
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, [])
        XCTAssertEqual(reload().hiddenAppBundleIdentifiers, [])
    }

    func testSetAppHiddenAddsAndRemoves() {
        let prefs = makePrefs()
        prefs.setAppHiddenInDocky(bundleIdentifier: "com.b", isHidden: true)
        prefs.setAppHiddenInDocky(bundleIdentifier: "com.a", isHidden: true)
        prefs.setAppHiddenInDocky(bundleIdentifier: "com.a", isHidden: true)
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, ["com.a", "com.b"])
        XCTAssertTrue(prefs.isAppHiddenInDocky(bundleIdentifier: "com.a"))
        prefs.setAppHiddenInDocky(bundleIdentifier: "com.a", isHidden: false)
        XCTAssertFalse(prefs.isAppHiddenInDocky(bundleIdentifier: "com.a"))
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, ["com.b"])
    }

    func testSetAppHiddenIgnoresEmptyIdentifier() {
        let prefs = makePrefs()
        prefs.setAppHiddenInDocky(bundleIdentifier: "", isHidden: true)
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, [])
    }

    func testWharfItselfIsAlwaysReportedHiddenAndNeverStored() throws {
        let own = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let prefs = makePrefs()
        XCTAssertTrue(prefs.isAppHiddenInDocky(bundleIdentifier: own))
        prefs.setAppHiddenInDocky(bundleIdentifier: own, isHidden: true)
        XCTAssertEqual(prefs.hiddenAppBundleIdentifiers, [])
        XCTAssertTrue(prefs.isAppHiddenInDocky(bundleIdentifier: own))
    }

    func testUnhidingAnAppThatWasNeverHiddenIsANoOp() {
        let prefs = makePrefs()
        prefs.setAppHiddenInDocky(bundleIdentifier: "com.never", isHidden: false)
        XCTAssertNil(defaults.object(forKey: PrefKeys.hiddenAppBundleIdentifiers))
    }

    // MARK: pinnedAppBundleIdentifiers and pinnedItems

    func testPinnedItemsDefaultToEmpty() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.pinnedItems, [])
        XCTAssertEqual(prefs.pinnedAppBundleIdentifiers, [])
    }

    func testLegacyPinnedAppListMigratesToAppItems() {
        defaults.set(["com.a", "com.b"], forKey: PrefKeys.pinnedAppBundleIdentifiers)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.pinnedItems, [.app(bundleIdentifier: "com.a"), .app(bundleIdentifier: "com.b")])
        XCTAssertEqual(prefs.pinnedAppBundleIdentifiers, ["com.a", "com.b"])
    }

    func testLegacyPinnedAppListIsIgnoredOnceItemsExist() {
        defaults.set(["legacy.app"], forKey: PrefKeys.pinnedAppBundleIdentifiers)
        defaults.set(encoded([PinnedTileItem.app(bundleIdentifier: "new.app")]), forKey: PrefKeys.pinnedItems)
        XCTAssertEqual(makePrefs().pinnedItems, [.app(bundleIdentifier: "new.app")])
    }

    func testCorruptPinnedItemsFallBackToTheLegacyList() {
        defaults.set(["legacy.app"], forKey: PrefKeys.pinnedAppBundleIdentifiers)
        defaults.set(Data("not json".utf8), forKey: PrefKeys.pinnedItems)
        XCTAssertEqual(makePrefs().pinnedItems, [.app(bundleIdentifier: "legacy.app")])
    }

    func testDuplicateLegacyPinnedAppsDoNotTrap() {
        defaults.set(["dup", "dup", "dup"], forKey: PrefKeys.pinnedAppBundleIdentifiers)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.pinnedItems.count, 3)
    }

    func testPinnedItemsSetterPersistsAndKeepsLegacyListInSync() {
        let prefs = makePrefs()
        prefs.pinnedItems = [
            .app(bundleIdentifier: "com.a"),
            .spacer(),
            .app(bundleIdentifier: "com.b"),
            .launchpad(id: "custom:lp"),
        ]
        XCTAssertEqual(prefs.pinnedAppBundleIdentifiers, ["com.a", "com.b"])
        XCTAssertEqual(defaults.stringArray(forKey: PrefKeys.pinnedAppBundleIdentifiers), ["com.a", "com.b"])
        let reloaded = reload()
        XCTAssertEqual(reloaded.pinnedItems.count, 4)
        XCTAssertEqual(reloaded.pinnedItems.first, .app(bundleIdentifier: "com.a"))
    }

    func testPinnedItemsSetterIgnoresIdenticalAssignment() {
        let prefs = makePrefs()
        prefs.pinnedItems = []
        XCTAssertNil(defaults.object(forKey: PrefKeys.pinnedItems))
    }

    func testPinnedItemsWithDuplicateIdsSurviveSetterAndReload() {
        let prefs = makePrefs()
        prefs.pinnedItems = Array(repeating: .app(bundleIdentifier: "dup"), count: 4)
        XCTAssertEqual(reload().pinnedItems.count, 4)
    }

    func testPinnedAppItemWithoutBundleIdentifierIsExcludedFromLegacyList() {
        let item = PinnedTileItem(
            id: "app:broken", kind: .app, bundleIdentifier: nil, folderDisplayName: nil,
            folderBundleIdentifiers: [], appFolderDisplayMode: nil, folderContentViewMode: nil,
            widgetKind: nil, widgetOwnerBundleIdentifier: nil, widgetSpan: nil,
            hiddenWidgetOwnerBundleIdentifiers: []
        )
        let prefs = makePrefs()
        prefs.pinnedItems = [item, .app(bundleIdentifier: "ok")]
        XCTAssertEqual(prefs.pinnedAppBundleIdentifiers, ["ok"])
    }

    // MARK: Item factories and codecs

    func testAppItemFactory() {
        let item = PinnedTileItem.app(bundleIdentifier: "com.x")
        XCTAssertEqual(item.id, "app:com.x")
        XCTAssertEqual(item.kind, .app)
        XCTAssertEqual(item.bundleIdentifier, "com.x")
        XCTAssertEqual(item.folderBundleIdentifiers, [])
    }

    func testAppFolderFactoryDefaults() {
        let item = PinnedTileItem.appFolder(bundleIdentifiers: ["a", "b"])
        XCTAssertTrue(item.id.hasPrefix("custom:"))
        XCTAssertEqual(item.folderDisplayName, "Folder")
        XCTAssertEqual(item.appFolderDisplayMode, .grid)
        XCTAssertEqual(item.folderContentViewMode, .grid)
        XCTAssertEqual(item.folderBundleIdentifiers, ["a", "b"])
    }

    func testFactoriesMintUniqueIds() {
        let ids = (0..<50).map { _ in PinnedTileItem.spacer().id }
        XCTAssertEqual(Set(ids).count, 50)
        let trailing = (0..<50).map { _ in TrailingTileItem.divider().id }
        XCTAssertEqual(Set(trailing).count, 50)
    }

    func testPinnedWidgetFactoryDefaultsToSpanThree() {
        XCTAssertEqual(PinnedTileItem.widget(kind: .clock, ownerBundleIdentifier: "o").widgetSpan, .three)
        XCTAssertEqual(TrailingTileItem.widget(kind: .clock, ownerBundleIdentifier: "o").widgetSpan, .three)
    }

    func testTrailingFolderEffectiveDefaults() {
        let item = TrailingTileItem.trash()
        XCTAssertEqual(item.effectiveFolderDisplayMode, .contents)
        XCTAssertEqual(item.effectiveFolderContentViewMode, .grid)
        XCTAssertEqual(item.effectiveFolderSortMode, .dateAdded)
    }

    func testTrailingFolderFactoriesCarryTheirModes() throws {
        let url = try XCTUnwrap(URL(string: "file:///tmp/"))
        let source = TrailingTileItem.folder(sourceTileID: "t1", displayMode: .folder, contentViewMode: .finder, sortMode: .size)
        XCTAssertEqual(source.id, "folder:t1")
        XCTAssertEqual(source.effectiveFolderDisplayMode, .folder)
        XCTAssertEqual(source.effectiveFolderContentViewMode, .finder)
        XCTAssertEqual(source.effectiveFolderSortMode, .size)

        let custom = TrailingTileItem.folder(id: "custom-folder:x", url: url, displayName: "Tmp")
        XCTAssertEqual(custom.folderURL, url)
        XCTAssertEqual(custom.folderDisplayName, "Tmp")
        XCTAssertNil(custom.sourceTileID)
    }

    func testTrashFactoryIsASingleton() {
        XCTAssertEqual(TrailingTileItem.trash().id, "trash")
        XCTAssertEqual(TrailingTileItem.trash(), TrailingTileItem.trash())
    }

    func testSmartStackFactoryUsesTheCatalogDefaultHiddenOwners() {
        XCTAssertEqual(
            PinnedTileItem.smartStack().hiddenWidgetOwnerBundleIdentifiers,
            WidgetCatalog.defaultHiddenSmartStackOwnerBundleIdentifiers
        )
        XCTAssertEqual(PinnedTileItem.smartStack(hiddenWidgetOwnerBundleIdentifiers: ["x"]).hiddenWidgetOwnerBundleIdentifiers, ["x"])
    }

    func testPinnedAndTrailingKindRawValuesArePersistedContract() {
        XCTAssertEqual(
            ["app", "appFolder", "launchpad", "startMenu", "widget", "smartStack", "spacer", "flexibleSpacer", "divider"],
            [PinnedTileItemKind.app, .appFolder, .launchpad, .startMenu, .widget, .smartStack, .spacer, .flexibleSpacer, .divider].map(\.rawValue)
        )
        XCTAssertEqual(
            ["folder", "trash", "widget", "smartStack", "spacer", "flexibleSpacer", "divider"],
            [TrailingTileItemKind.folder, .trash, .widget, .smartStack, .spacer, .flexibleSpacer, .divider].map(\.rawValue)
        )
    }

    // MARK: Trailing items, widget placements, app widget displays

    func testTrailingItemsSetterPersistsAndReloads() throws {
        let url = try XCTUnwrap(URL(string: "file:///Users/someone/Downloads/"))
        let prefs = makePrefs()
        let items: [TrailingTileItem] = [.folder(id: "custom-folder:1", url: url, displayName: "Downloads"), .trash()]
        prefs.trailingItems = items
        XCTAssertEqual(reload().trailingItems, items)
    }

    func testWidgetPlacementsSetterPersistsAndReloads() {
        let prefs = makePrefs()
        let placements = [
            WidgetPlacement(kind: .weather, ownerBundleIdentifier: "com.apple.weather", span: .three),
            WidgetPlacement(kind: .external("com.example.W"), ownerBundleIdentifier: "com.example", span: .one),
        ]
        prefs.widgetPlacements = placements
        XCTAssertEqual(reload().widgetPlacements, placements)
    }

    func testWidgetPlacementIdCombinesOwnerAndKind() {
        let placement = WidgetPlacement(kind: .clock, ownerBundleIdentifier: "com.owner", span: .one)
        XCTAssertEqual(placement.id, "com.owner:clock")
    }

    func testAppWidgetDisplaysSetterPersistsAndReloads() {
        let prefs = makePrefs()
        let displays = [AppWidgetDisplay(bundleIdentifier: "com.apple.mail", kind: .reminders, span: .two)]
        prefs.appWidgetDisplays = displays
        XCTAssertEqual(reload().appWidgetDisplays, displays)
    }

    func testStoredWidgetPlacementsWithAnUnknownKindLoadAsEmpty() {
        defaults.set(json("[{\"kind\":\"from-the-future\",\"ownerBundleIdentifier\":\"o\",\"span\":1}]"), forKey: PrefKeys.widgetPlacements)
        XCTAssertEqual(makePrefs().widgetPlacements, [])
    }

    func testTileStoreFieldsAreIndependent() {
        let prefs = makePrefs()
        prefs.pinnedItems = [.app(bundleIdentifier: "p")]
        prefs.trailingItems = [.trash()]
        let reloaded = reload()
        XCTAssertEqual(reloaded.pinnedItems.count, 1)
        XCTAssertEqual(reloaded.trailingItems, [.trash()])
        XCTAssertEqual(reloaded.widgetPlacements, [])
        XCTAssertEqual(reloaded.appWidgetDisplays, [])
    }

    // MARK: applyProfile

    func testApplyProfileLoadsAllFiveFieldsAndPersistsThem() {
        let prefs = makePrefs()
        let profile = DockProfile(
            name: "Work",
            pinnedItems: [.app(bundleIdentifier: "com.work")],
            trailingItems: [.trash()],
            widgetPlacements: [WidgetPlacement(kind: .clock, ownerBundleIdentifier: "o", span: .two)],
            appWidgetDisplays: [AppWidgetDisplay(bundleIdentifier: "b", kind: .weather, span: .one)],
            hiddenAppBundleIdentifiers: ["z.hidden", "a.hidden"]
        )
        prefs.applyProfile(profile)
        let reloaded = reload()
        XCTAssertEqual(reloaded.pinnedItems, profile.pinnedItems)
        XCTAssertEqual(reloaded.trailingItems, profile.trailingItems)
        XCTAssertEqual(reloaded.widgetPlacements, profile.widgetPlacements)
        XCTAssertEqual(reloaded.appWidgetDisplays, profile.appWidgetDisplays)
        XCTAssertEqual(reloaded.hiddenAppBundleIdentifiers, ["a.hidden", "z.hidden"])
    }

    func testApplyProfileResetsTheMirroringFlagAfterwards() {
        let prefs = makePrefs()
        prefs.isApplyingProfile = false
        prefs.applyProfile(DockProfile(name: "Empty"))
        XCTAssertFalse(prefs.isApplyingProfile)
        // Leave the instance safe for teardown.
        prefs.isApplyingProfile = true
    }
}
