import XCTest
@testable import Wharf

/// The theme override layer (which appearance keys the user has customized), the
/// first-launch migration that seeds it, per-preference persistence, and the
/// three reset functions.
final class AppearanceOverrideTests: DockyPreferencesTestCase {

    /// Every fixture value on a pristine instance backed by an empty suite.
    private func pristineSnapshot() -> [String: String] {
        let name = "WharfTests-pristine-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.set(true, forKey: PrefKeys.opensAtLogin)
        suite.set(true, forKey: PrefKeys.hidesSystemDock)
        defer { Self.discardSuite(named: name) }
        let prefs = DockyPreferences(defaults: suite)
        prefs.isApplyingProfile = true
        prefs.isSyncingOpenAtLoginPreference = true
        return Dictionary(uniqueKeysWithValues: PreferenceMutations.all.map { ($0.name, $0.read(prefs)) })
    }

    private func applyEveryMutation(to prefs: DockyPreferences) {
        for mutation in PreferenceMutations.all {
            mutation.mutate(prefs)
        }
    }

    // MARK: Fixture integrity

    func testMutationNamesAndKeysAreUnique() {
        let all = PreferenceMutations.all
        XCTAssertEqual(Set(all.map(\.name)).count, all.count)
        XCTAssertEqual(Set(all.map(\.key)).count, all.count)
    }

    func testEveryAppearanceKeyHasAFixture() {
        let covered = Set(PreferenceMutations.all.map(\.key))
        XCTAssertEqual(DockyPreferences.appearanceKeys.subtracting(covered), [])
    }

    func testEveryMutationActuallyChangesItsValue() {
        let baseline = pristineSnapshot()
        let prefs = makePrefs()
        for mutation in PreferenceMutations.all {
            mutation.mutate(prefs)
            XCTAssertNotEqual(mutation.read(prefs), baseline[mutation.name], mutation.name)
        }
    }

    // MARK: Persistence of every preference

    func testEveryMutationIsWrittenToItsStorageKey() {
        let prefs = makePrefs()
        for mutation in PreferenceMutations.all {
            mutation.mutate(prefs)
            XCTAssertNotNil(defaults.object(forKey: mutation.key), "\(mutation.name) -> \(mutation.key)")
        }
    }

    func testEveryMutationSurvivesAReload() {
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        let reloaded = reload()
        for mutation in PreferenceMutations.all {
            XCTAssertEqual(mutation.read(reloaded), mutation.read(prefs), mutation.name)
        }
    }

    func testMutationsDoNotWriteAnyUnexpectedKeys() {
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        let known = Set(PreferenceMutations.all.map(\.key))
            .union([
                PrefKeys.opensAtLogin, PrefKeys.hidesSystemDock,
                PrefKeys.userOverriddenAppearanceKeys, PrefKeys.appearanceOverrideMigrationVersion,
            ])
        let written = Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? [])
        XCTAssertEqual(written.subtracting(known), [], "a setter writes a key that is not in the key table")
    }

    func testOptionalClearRemovesTheStoredKey() {
        let prefs = makePrefs()
        for mutation in PreferenceMutations.all {
            guard let clear = mutation.clear else { continue }
            mutation.mutate(prefs)
            XCTAssertNotNil(defaults.object(forKey: mutation.key), mutation.name)
            clear(prefs)
            XCTAssertNil(defaults.object(forKey: mutation.key), mutation.name)
        }
    }

    // MARK: Override flags

    func testNothingIsOverriddenOnAPristineInstance() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [])
        for key in DockyPreferences.appearanceKeys {
            XCTAssertFalse(prefs.isAppearanceOverridden(key), key)
        }
    }

    func testEveryAppearanceSetterMarksItsKeyOverridden() {
        for mutation in PreferenceMutations.appearance {
            let prefs = makePrefs()
            mutation.mutate(prefs)
            XCTAssertTrue(prefs.isAppearanceOverridden(mutation.key), mutation.name)
        }
    }

    func testBehaviorSettersNeverMarkAppearanceOverrides() {
        let prefs = makePrefs()
        for mutation in PreferenceMutations.behavior {
            mutation.mutate(prefs)
        }
        // windowAxisSizing marks itself; see the relaunch test below for why that is a bug.
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys.subtracting([PrefKeys.windowAxisSizing]), [])
    }

    /// `windowAxisSizing` marks itself overridden so a theme cannot replace the
    /// user's choice, but its key is missing from `appearanceKeys`. On the next
    /// launch the stored flag list is intersected with `appearanceKeys`, so the
    /// flag is dropped and an active theme's `behavior.windowAxisSizing` wins.
    func testWindowAxisSizingOverrideSurvivesRelaunch() {
        let prefs = makePrefs()
        prefs.windowAxisSizing = .fullAxis
        XCTAssertTrue(prefs.isAppearanceOverridden(PrefKeys.windowAxisSizing))
        let reloaded = reload()
        XCTExpectFailure("BUG: windowAxisSizing is marked as an override but is not in appearanceKeys, so the flag is dropped on relaunch") {
            XCTAssertTrue(reloaded.isAppearanceOverridden(PrefKeys.windowAxisSizing))
        }
    }

    func testOverrideFlagsPersistAndReload() {
        let prefs = makePrefs()
        prefs.tileSpacing = 4
        prefs.dividerOpacity = 0.4
        let reloaded = reload()
        XCTAssertTrue(reloaded.isAppearanceOverridden(PrefKeys.tileSpacing))
        XCTAssertTrue(reloaded.isAppearanceOverridden(PrefKeys.dividerOpacity))
        XCTAssertFalse(reloaded.isAppearanceOverridden(PrefKeys.tileVerticalPadding))
    }

    func testClearingAnOptionalAppearanceValueClearsItsOverrideFlag() {
        for mutation in PreferenceMutations.appearance {
            guard let clear = mutation.clear else { continue }
            let prefs = makePrefs()
            mutation.mutate(prefs)
            clear(prefs)
            if mutation.name.hasPrefix("windowCornerRadius") {
                continue // covered by the known-gap test below
            }
            XCTAssertFalse(prefs.isAppearanceOverridden(mutation.key), mutation.name)
        }
    }

    func testClearingAPerCornerRadiusClearsItsOverrideFlag() {
        for mutation in PreferenceMutations.appearance where mutation.name.hasPrefix("windowCornerRadius") && mutation.clear != nil {
            let prefs = makePrefs()
            mutation.mutate(prefs)
            mutation.clear?(prefs)
            XCTExpectFailure("BUG: \(mutation.name) setter marks the override even when the value goes back to nil") {
                XCTAssertFalse(prefs.isAppearanceOverridden(mutation.key), mutation.name)
            }
        }
    }

    func testMarkAndClearAreIdempotent() {
        let prefs = makePrefs()
        prefs.markAppearanceOverride(PrefKeys.tileSpacing)
        prefs.markAppearanceOverride(PrefKeys.tileSpacing)
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [PrefKeys.tileSpacing])
        prefs.clearAppearanceOverride(PrefKeys.tileSpacing)
        prefs.clearAppearanceOverride(PrefKeys.tileSpacing)
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [])
    }

    func testClearingOneOverrideKeepsStoredValueAndOtherOverrides() {
        let prefs = makePrefs()
        prefs.tileSpacing = 9
        prefs.tileIconPadding = 2
        prefs.clearAppearanceOverride(PrefKeys.tileSpacing)
        XCTAssertEqual(defaults.object(forKey: PrefKeys.tileSpacing) as? Double, 9)
        XCTAssertFalse(prefs.isAppearanceOverridden(PrefKeys.tileSpacing))
        XCTAssertTrue(prefs.isAppearanceOverridden(PrefKeys.tileIconPadding))
    }

    func testClearAllRemovesEveryOverride() {
        let prefs = makePrefs()
        for mutation in PreferenceMutations.appearance {
            mutation.mutate(prefs)
        }
        XCTAssertFalse(prefs.userOverriddenAppearanceKeys.isEmpty)
        prefs.clearAllAppearanceOverrides()
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [])
        XCTAssertEqual(reload().userOverriddenAppearanceKeys, [])
    }

    // MARK: Migration of existing preferences

    func testExistingAppearanceKeysAreTreatedAsOverridesOnFirstLaunch() {
        defaults.set(11.0, forKey: PrefKeys.tileVerticalPadding)
        defaults.set("circle", forKey: PrefKeys.windowClipShape)
        let prefs = makePrefs()
        XCTAssertTrue(prefs.isAppearanceOverridden(PrefKeys.tileVerticalPadding))
        XCTAssertTrue(prefs.isAppearanceOverridden(PrefKeys.windowClipShape))
        XCTAssertFalse(prefs.isAppearanceOverridden(PrefKeys.tileSpacing))
    }

    func testMigrationIgnoresNonAppearanceKeys() {
        defaults.set(true, forKey: PrefKeys.autohidesWindow)
        defaults.set(3, forKey: PrefKeys.dockRowCount)
        XCTAssertEqual(makePrefs().userOverriddenAppearanceKeys, [])
    }

    func testMigrationRunsOnceAndRecordsItsVersion() {
        defaults.set(11.0, forKey: PrefKeys.tileVerticalPadding)
        _ = makePrefs()
        XCTAssertEqual(defaults.integer(forKey: PrefKeys.appearanceOverrideMigrationVersion), 1)

        // The user later reverts that one setting to the theme value.
        let second = makePrefs()
        second.clearAppearanceOverride(PrefKeys.tileVerticalPadding)
        XCTAssertFalse(makePrefs().isAppearanceOverridden(PrefKeys.tileVerticalPadding), "migration must not re-seed")
    }

    func testMigrationMergesWithAStoredOverrideList() {
        defaults.set([PrefKeys.tileSpacing], forKey: PrefKeys.userOverriddenAppearanceKeys)
        defaults.set(2.0, forKey: PrefKeys.tileIconPadding)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [PrefKeys.tileSpacing, PrefKeys.tileIconPadding])
    }

    func testStoredOverrideListDropsUnknownKeys() {
        defaults.set(
            [PrefKeys.tileSpacing, "docky.notAnAppearanceKey", PrefKeys.autohidesWindow, "", "../x"],
            forKey: PrefKeys.userOverriddenAppearanceKeys
        )
        defaults.set(1, forKey: PrefKeys.appearanceOverrideMigrationVersion)
        XCTAssertEqual(makePrefs().userOverriddenAppearanceKeys, [PrefKeys.tileSpacing])
    }

    func testStoredOverrideListOfWrongTypeIsIgnored() {
        defaults.set(1, forKey: PrefKeys.appearanceOverrideMigrationVersion)
        for wrong in ["tileSpacing", [1, 2], ["k": "v"], Data([1])] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.userOverriddenAppearanceKeys)
            XCTAssertEqual(makePrefs().userOverriddenAppearanceKeys, [], "\(type(of: wrong))")
        }
    }

    func testHugeStoredOverrideListIsFilteredWithoutTrapping() {
        let junk = (0..<20_000).map { "junk.\($0)" }
        defaults.set(junk + [PrefKeys.tileSpacing], forKey: PrefKeys.userOverriddenAppearanceKeys)
        defaults.set(1, forKey: PrefKeys.appearanceOverrideMigrationVersion)
        XCTAssertEqual(makePrefs().userOverriddenAppearanceKeys, [PrefKeys.tileSpacing])
    }

    func testNegativeOrGarbageMigrationVersionStillMigrates() {
        defaults.set(-5, forKey: PrefKeys.appearanceOverrideMigrationVersion)
        defaults.set(3.0, forKey: PrefKeys.tileSpacing)
        XCTAssertTrue(makePrefs().isAppearanceOverridden(PrefKeys.tileSpacing))
        XCTAssertEqual(defaults.integer(forKey: PrefKeys.appearanceOverrideMigrationVersion), 1)
    }

    // MARK: Resets

    func testResetAppearanceRestoresEveryAppearanceDefault() {
        let baseline = pristineSnapshot()
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        prefs.resetAppearanceToDefaults()
        for mutation in PreferenceMutations.appearance where mutation.name != "showsActivePinnedSeparator" {
            XCTAssertEqual(mutation.read(prefs), baseline[mutation.name], mutation.name)
        }
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [])
    }

    func testResetAppearanceLeavesBehaviorAlone() {
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        let before = Dictionary(uniqueKeysWithValues: PreferenceMutations.behavior.map { ($0.name, $0.read(prefs)) })
        prefs.resetAppearanceToDefaults()
        for mutation in PreferenceMutations.behavior {
            XCTAssertEqual(mutation.read(prefs), before[mutation.name], mutation.name)
        }
    }

    func testResetAppearancePersistsAcrossReload() {
        let baseline = pristineSnapshot()
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        prefs.resetAppearanceToDefaults()
        let reloaded = reload()
        for mutation in PreferenceMutations.appearance where mutation.name != "showsActivePinnedSeparator" {
            XCTAssertEqual(mutation.read(reloaded), baseline[mutation.name], mutation.name)
        }
        XCTAssertEqual(reloaded.userOverriddenAppearanceKeys, [])
    }

    func testResetBehaviorRestoresTheBehaviorPaneDefaults() {
        let baseline = pristineSnapshot()
        let inPane: Set<String> = [
            "windowDisplayTarget", "windowSpaceBehavior", "windowAxisSizing", "maximizedWindowBehavior",
            "overflowBehavior", "autohidesWindow", "dockContentMode", "windowGrouping",
            "showsOnlyCurrentScreenWindows", "dockRowCount", "collapsesToButton", "showsMediaProgressOnTiles",
            "dockStaysBehindBundleIDs", "windowsKeyboardMode", "windowsKeyboardSnipShortcut",
            "windowsKeyboardExcludedBundleIDs", "showsAppBadges", "folderBadgeMode", "folderBadgePreviewStyle",
            "autohideWindowDelay", "autohideAnimationDuration", "hidesDuringFullscreen", "fullscreenRevealDelay",
            "enablesShelveMode", "shelveHidesFinder", "shelveHidesTrash", "hidesRecentApps", "showsRunningApps",
            "showsMinimizedWindows", "showsActivePinnedSeparator", "appTileFrontmostClickBehavior",
            "showsGroupedOpenedAppsInDock", "showsGroupedOpenedAppsBackdrop", "enablesWidgetHoverPreview",
            "widgetHoverPreviewSpans", "widgetHoverPreviewDelay", "windowPreviewHoverDelay", "windowPreviewLayout",
        ]
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        prefs.resetBehaviorToDefaults()
        for mutation in PreferenceMutations.all where inPane.contains(mutation.name) {
            XCTAssertEqual(mutation.read(prefs), baseline[mutation.name], mutation.name)
        }
        XCTAssertEqual(prefs.userOverriddenAppearanceKeys, [])
    }

    func testResetBehaviorLeavesHiddenAppsIconsAndLaunchpadAlone() {
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        let untouched = ["hiddenAppBundleIdentifiers", "appIconOverrides", "launchpadGridColumnCount", "launchpadShortcut",
                         "windowSwitcherShortcut", "tileSpacing", "windowCornerRadius"]
        let before = Dictionary(uniqueKeysWithValues: PreferenceMutations.all.map { ($0.name, $0.read(prefs)) })
        prefs.resetBehaviorToDefaults()
        for mutation in PreferenceMutations.all where untouched.contains(mutation.name) {
            XCTAssertEqual(mutation.read(prefs), before[mutation.name], mutation.name)
        }
    }

    func testResetToDefaultsRestoresTheKeysItCovers() {
        let baseline = pristineSnapshot()
        let covered: Set<String> = [
            "tileVerticalPadding", "tileSpacing", "tileClipShape", "windowCornerRadius", "windowClipShape",
            "windowTintColor", "windowTintOpacity", "disablesGlassLook", "windowBackgroundImagePath",
            "windowBackgroundImageMode", "windowDisplayTarget", "windowSpaceBehavior", "autohidesWindow",
            "dockContentMode", "windowGrouping", "showsOnlyCurrentScreenWindows", "dockRowCount",
            "collapsesToButton", "showsMediaProgressOnTiles", "dockStaysBehindBundleIDs", "windowsKeyboardMode",
            "windowsKeyboardSnipShortcut", "windowsKeyboardExcludedBundleIDs", "showsAppBadges",
            "folderBadgeMode", "folderBadgePreviewStyle", "autohideWindowDelay", "autohideAnimationDuration",
            "fullscreenRevealDelay", "windowPreviewHoverDelay", "windowPreviewLayout", "maximizedWindowBehavior",
            "overflowBehavior", "windowAxisSizing", "enablesWidgetHoverPreview", "widgetHoverPreviewSpans",
            "widgetHoverPreviewDelay", "showsActivePinnedSeparator", "showsRunningApps", "showsMinimizedWindows",
            "hidesDuringFullscreen", "enablesShelveMode", "shelveHidesFinder", "shelveHidesTrash", "hidesRecentApps",
            "appTileFrontmostClickBehavior", "activeIndicatorShape", "activeIndicatorImagePath",
            "activeIndicatorColor", "dividerImagePath", "leftDividerImagePath", "rightDividerImagePath",
            "mirrorsLeftDividerOnRight", "activeIndicatorOffset", "activeIndicatorScale",
            "dividerPaddingFraction", "dividerImageScale", "dividerOffset", "dividerOpacity",
            "appIconOverrides", "trashIconOverrides", "folderIconOverrides", "launchpadIconPath",
            "launchpadIconPaddingFraction", "startMenuIconPath", "startMenuIconPaddingFraction",
            "hiddenAppBundleIdentifiers", "showsGroupedOpenedAppsInDock", "showsGroupedOpenedAppsBackdrop",
            "enablesLaunchpadOverlay", "enablesStartMenuOverlay", "opensStartMenuFromFinderTile",
            "launchpadOverlayTransparency", "launchpadGridColumnCount", "launchpadGridRowCount",
            "launchpadShortcut", "enablesWindowSwitcher", "includesMinimizedWindows", "windowSwitcherShortcut",
            "showsWindowSwitcherFocusPreview", "windowSwitcherPreviewMode", "windowSwitcherLayout",
            "switcherMinimizeKeyCode", "switcherCloseKeyCode", "switcherZoomKeyCode", "hasSeenDockEditorHint",
        ]
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        prefs.resetToDefaults()
        for mutation in PreferenceMutations.all where covered.contains(mutation.name) {
            XCTAssertEqual(mutation.read(prefs), baseline[mutation.name], mutation.name)
        }
    }

    func testResetToDefaultsLeavesPinnedItemsAndTrailingItemsAlone() {
        let prefs = makePrefs()
        prefs.pinnedItems = [.app(bundleIdentifier: "keep.me")]
        prefs.trailingItems = [.trash()]
        prefs.widgetPlacements = [WidgetPlacement(kind: .clock, ownerBundleIdentifier: "o", span: .one)]
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.pinnedItems, [.app(bundleIdentifier: "keep.me")])
        XCTAssertEqual(prefs.trailingItems, [.trash()])
        XCTAssertEqual(prefs.widgetPlacements.count, 1)
    }

    /// `resetAppearanceToDefaults` documents that a full wipe is `resetToDefaults`,
    /// yet the latter never touches these appearance preferences.
    func testResetToDefaultsIsAFullAppearanceReset() {
        let baseline = pristineSnapshot()
        let prefs = makePrefs()
        applyEveryMutation(to: prefs)
        prefs.resetToDefaults()
        let leftBehind = PreferenceMutations.appearance
            .filter { $0.read(prefs) != baseline[$0.name] }
            .map(\.name)
        XCTExpectFailure("BUG: resetToDefaults skips appearance preferences: \(leftBehind.prefix(6).joined(separator: ", ")) ...") {
            XCTAssertEqual(leftBehind, [])
        }
    }
}
