import XCTest
@testable import Wharf

/// Every persisted key, pinned as a literal. A key renamed in source silently
/// resets that setting for every existing user, so a rename must fail a test and
/// be a deliberate, migrated change.
final class StorageKeyContractTests: DockyPreferencesTestCase {
    private let expected: [(property: String, actual: String, literal: String)] = [
        ("tileVerticalPadding", PrefKeys.tileVerticalPadding, "docky.tileVerticalPadding"),
        ("tileSpacing", PrefKeys.tileSpacing, "docky.tileSpacing"),
        ("tileClipShape", PrefKeys.tileClipShape, "docky.tileClipShape"),
        ("tileIconPadding", PrefKeys.tileIconPadding, "docky.tileIconPadding"),
        ("tileHoverOpacity", PrefKeys.tileHoverOpacity, "docky.tileHoverOpacity"),
        ("tileHoverScale", PrefKeys.tileHoverScale, "docky.tileHoverScale"),
        ("tileHoverBackgroundColor", PrefKeys.tileHoverBackgroundColor, "docky.tileHoverBackgroundColor"),
        ("tileHoverBackgroundImagePath", PrefKeys.tileHoverBackgroundImagePath, "docky.tileHoverBackgroundImagePath"),
        ("tileHoverBackgroundOpacity", PrefKeys.tileHoverBackgroundOpacity, "docky.tileHoverBackgroundOpacity"),
        ("tileHoverBackgroundCornerRadius", PrefKeys.tileHoverBackgroundCornerRadius, "docky.tileHoverBackgroundCornerRadius"),
        ("tileActiveBackgroundColor", PrefKeys.tileActiveBackgroundColor, "docky.tileActiveBackgroundColor"),
        ("tileActiveBackgroundImagePath", PrefKeys.tileActiveBackgroundImagePath, "docky.tileActiveBackgroundImagePath"),
        ("tileActiveBackgroundOpacity", PrefKeys.tileActiveBackgroundOpacity, "docky.tileActiveBackgroundOpacity"),
        ("tileActiveBackgroundCornerRadius", PrefKeys.tileActiveBackgroundCornerRadius, "docky.tileActiveBackgroundCornerRadius"),
        ("widget1xContentPadding", PrefKeys.widget1xContentPadding, "docky.widget1xContentPadding"),
        ("widget1xCornerRadius", PrefKeys.widget1xCornerRadius, "docky.widget1xCornerRadius"),
        ("widget2xContentPadding", PrefKeys.widget2xContentPadding, "docky.widget2xContentPadding"),
        ("widget2xCornerRadius", PrefKeys.widget2xCornerRadius, "docky.widget2xCornerRadius"),
        ("widget3xContentPadding", PrefKeys.widget3xContentPadding, "docky.widget3xContentPadding"),
        ("widget3xCornerRadius", PrefKeys.widget3xCornerRadius, "docky.widget3xCornerRadius"),
        ("widget4xContentPadding", PrefKeys.widget4xContentPadding, "docky.widget4xContentPadding"),
        ("widget4xCornerRadius", PrefKeys.widget4xCornerRadius, "docky.widget4xCornerRadius"),
        ("windowCornerRadius", PrefKeys.windowCornerRadius, "docky.windowCornerRadius"),
        ("windowCornerRadiusTopLeading", PrefKeys.windowCornerRadiusTopLeading, "docky.windowCornerRadiusTopLeading"),
        ("windowCornerRadiusTopTrailing", PrefKeys.windowCornerRadiusTopTrailing, "docky.windowCornerRadiusTopTrailing"),
        ("windowCornerRadiusBottomLeading", PrefKeys.windowCornerRadiusBottomLeading, "docky.windowCornerRadiusBottomLeading"),
        ("windowCornerRadiusBottomTrailing", PrefKeys.windowCornerRadiusBottomTrailing, "docky.windowCornerRadiusBottomTrailing"),
        ("windowContentInsetTop", PrefKeys.windowContentInsetTop, "docky.windowContentInsetTop"),
        ("windowContentInsetLeading", PrefKeys.windowContentInsetLeading, "docky.windowContentInsetLeading"),
        ("windowContentInsetBottom", PrefKeys.windowContentInsetBottom, "docky.windowContentInsetBottom"),
        ("windowContentInsetTrailing", PrefKeys.windowContentInsetTrailing, "docky.windowContentInsetTrailing"),
        ("windowClipShape", PrefKeys.windowClipShape, "docky.windowClipShape"),
        ("windowTintColor", PrefKeys.windowTintColor, "docky.windowTintColor"),
        ("windowTintOpacity", PrefKeys.windowTintOpacity, "docky.windowTintOpacity"),
        ("disablesGlassLook", PrefKeys.disablesGlassLook, "docky.disablesGlassLook"),
        ("windowBackgroundImagePath", PrefKeys.windowBackgroundImagePath, "docky.windowBackgroundImagePath"),
        ("windowBackgroundImageMode", PrefKeys.windowBackgroundImageMode, "docky.windowBackgroundImageMode"),
        ("windowPosition", PrefKeys.windowPosition, "docky.windowPosition"),
        ("windowDisplayTarget", PrefKeys.windowDisplayTarget, "docky.windowDisplayTarget"),
        ("windowSpaceBehavior", PrefKeys.windowSpaceBehavior, "docky.windowSpaceBehavior"),
        ("autohidesWindow", PrefKeys.autohidesWindow, "docky.autohidesWindow"),
        ("dockContentMode", PrefKeys.dockContentMode, "wharf.dockContentMode"),
        ("windowGrouping", PrefKeys.windowGrouping, "wharf.windowGrouping"),
        ("showsOnlyCurrentScreenWindows", PrefKeys.showsOnlyCurrentScreenWindows, "wharf.showsOnlyCurrentScreenWindows"),
        ("dockRowCount", PrefKeys.dockRowCount, "wharf.dockRowCount"),
        ("collapsesToButton", PrefKeys.collapsesToButton, "wharf.collapsesToButton"),
        ("showsMediaProgressOnTiles", PrefKeys.showsMediaProgressOnTiles, "wharf.showsMediaProgressOnTiles"),
        ("dockStaysBehindBundleIDs", PrefKeys.dockStaysBehindBundleIDs, "wharf.dockStaysBehindBundleIDs"),
        ("windowsKeyboardMode", PrefKeys.windowsKeyboardMode, "wharf.windowsKeyboardMode"),
        ("windowsKeyboardSnipShortcut", PrefKeys.windowsKeyboardSnipShortcut, "wharf.windowsKeyboardSnipShortcut"),
        ("windowsKeyboardExcludedBundleIDs", PrefKeys.windowsKeyboardExcludedBundleIDs, "wharf.windowsKeyboardExcludedBundleIDs"),
        ("showsAppBadges", PrefKeys.showsAppBadges, "docky.showsAppBadges"),
        ("folderBadgeMode", PrefKeys.folderBadgeMode, "docky.folderBadgeMode"),
        ("folderBadgePreviewStyle", PrefKeys.folderBadgePreviewStyle, "docky.folderBadgePreviewStyle"),
        ("opensAtLogin", PrefKeys.opensAtLogin, "docky.opensAtLogin"),
        ("autohideWindowDelay", PrefKeys.autohideWindowDelay, "docky.autohideWindowDelay"),
        ("autohideAnimationDuration", PrefKeys.autohideAnimationDuration, "docky.autohideAnimationDuration"),
        ("fullscreenRevealDelay", PrefKeys.fullscreenRevealDelay, "docky.fullscreenRevealDelay"),
        ("windowPreviewHoverDelay", PrefKeys.windowPreviewHoverDelay, "docky.windowPreviewHoverDelay"),
        ("windowPreviewLayout", PrefKeys.windowPreviewLayout, "docky.windowPreviewLayout"),
        ("maximizedWindowBehavior", PrefKeys.maximizedWindowBehavior, "docky.maximizedWindowBehavior"),
        ("hidesSystemDock", PrefKeys.hidesSystemDock, "docky.hidesSystemDock"),
        ("overflowBehavior", PrefKeys.overflowBehavior, "docky.overflowBehavior"),
        ("windowAxisSizing", PrefKeys.windowAxisSizing, "docky.windowAxisSizing"),
        ("enablesWidgetHoverPreview", PrefKeys.enablesWidgetHoverPreview, "docky.enablesWidgetHoverPreview"),
        ("widgetHoverPreviewSpans", PrefKeys.widgetHoverPreviewSpans, "docky.widgetHoverPreviewSpans"),
        ("widgetHoverPreviewDelay", PrefKeys.widgetHoverPreviewDelay, "docky.widgetHoverGrowDelay"),
        ("showsActivePinnedSeparator", PrefKeys.showsActivePinnedSeparator, "docky.showsActivePinnedSeparator"),
        ("showsRunningApps", PrefKeys.showsRunningApps, "docky.showsRunningApps"),
        ("showsMinimizedWindows", PrefKeys.showsMinimizedWindows, "docky.showsMinimizedWindows"),
        ("hidesDuringFullscreen", PrefKeys.hidesDuringFullscreen, "docky.hidesDuringFullscreen"),
        ("enablesShelveMode", PrefKeys.enablesShelveMode, "docky.enablesShelveMode"),
        ("shelveHidesFinder", PrefKeys.shelveHidesFinder, "docky.shelveHidesFinder"),
        ("shelveHidesTrash", PrefKeys.shelveHidesTrash, "docky.shelveHidesTrash"),
        ("hidesRecentApps", PrefKeys.hidesRecentApps, "docky.hidesRecentApps"),
        ("hidesProfileStrip", PrefKeys.hidesProfileStrip, "docky.hidesProfileStrip"),
        ("appTileFrontmostClickBehavior", PrefKeys.appTileFrontmostClickBehavior, "docky.appTileFrontmostClickBehavior"),
        ("activeIndicatorShape", PrefKeys.activeIndicatorShape, "docky.activeIndicatorShape"),
        ("activeIndicatorImagePath", PrefKeys.activeIndicatorImagePath, "docky.activeIndicatorImagePath"),
        ("activeIndicatorColor", PrefKeys.activeIndicatorColor, "docky.activeIndicatorColor"),
        ("dividerImagePath", PrefKeys.dividerImagePath, "docky.dividerImagePath"),
        ("leftDividerImagePath", PrefKeys.leftDividerImagePath, "docky.leftDividerImagePath"),
        ("rightDividerImagePath", PrefKeys.rightDividerImagePath, "docky.rightDividerImagePath"),
        ("mirrorsLeftDividerOnRight", PrefKeys.mirrorsLeftDividerOnRight, "docky.mirrorsLeftDividerOnRight"),
        ("activeIndicatorOffset", PrefKeys.activeIndicatorOffset, "docky.activeIndicatorOffset"),
        ("activeIndicatorScale", PrefKeys.activeIndicatorScale, "docky.activeIndicatorScale"),
        ("dividerPaddingFraction", PrefKeys.dividerPaddingFraction, "docky.dividerPaddingFraction"),
        ("dividerImageScale", PrefKeys.dividerImageScale, "docky.dividerImageScale"),
        ("dividerOffset", PrefKeys.dividerOffset, "docky.dividerOffset"),
        ("dividerOpacity", PrefKeys.dividerOpacity, "docky.dividerOpacity"),
        ("dividerColor", PrefKeys.dividerColor, "docky.dividerColor"),
        ("windowBorderColor", PrefKeys.windowBorderColor, "docky.windowBorderColor"),
        ("windowBorderWidth", PrefKeys.windowBorderWidth, "docky.windowBorderWidth"),
        ("iconShadowColor", PrefKeys.iconShadowColor, "docky.iconShadowColor"),
        ("iconShadowRadius", PrefKeys.iconShadowRadius, "docky.iconShadowRadius"),
        ("iconShadowOpacity", PrefKeys.iconShadowOpacity, "docky.iconShadowOpacity"),
        ("appIconOverrides", PrefKeys.appIconOverrides, "docky.appIconOverrides"),
        ("trashIconOverrides", PrefKeys.trashIconOverrides, "docky.trashIconOverrides"),
        ("folderIconOverrides", PrefKeys.folderIconOverrides, "docky.folderIconOverrides"),
        ("launchpadIconPath", PrefKeys.launchpadIconPath, "docky.launchpadIconPath"),
        ("launchpadIconPaddingFraction", PrefKeys.launchpadIconPaddingFraction, "docky.launchpadIconPaddingFraction"),
        ("startMenuIconPath", PrefKeys.startMenuIconPath, "docky.startMenuIconPath"),
        ("startMenuIconPaddingFraction", PrefKeys.startMenuIconPaddingFraction, "docky.startMenuIconPaddingFraction"),
        ("hiddenAppBundleIdentifiers", PrefKeys.hiddenAppBundleIdentifiers, "docky.hiddenAppBundleIdentifiers"),
        ("showsGroupedOpenedAppsInDock", PrefKeys.showsGroupedOpenedAppsInDock, "docky.showsGroupedOpenedAppsInDock"),
        ("showsGroupedOpenedAppsBackdrop", PrefKeys.showsGroupedOpenedAppsBackdrop, "docky.showsGroupedOpenedAppsBackdrop"),
        ("enablesLaunchpadOverlay", PrefKeys.enablesLaunchpadOverlay, "docky.enablesLaunchpadOverlay"),
        ("enablesStartMenuOverlay", PrefKeys.enablesStartMenuOverlay, "docky.enablesStartMenuOverlay"),
        ("opensStartMenuFromFinderTile", PrefKeys.opensStartMenuFromFinderTile, "docky.opensStartMenuFromFinderTile"),
        ("launchpadOverlayTransparency", PrefKeys.launchpadOverlayTransparency, "docky.launchpadOverlayTransparency"),
        ("launchpadGridColumnCount", PrefKeys.launchpadGridColumnCount, "docky.launchpadGridColumnCount"),
        ("launchpadGridRowCount", PrefKeys.launchpadGridRowCount, "docky.launchpadGridRowCount"),
        ("launchpadBaseIconSize", PrefKeys.launchpadBaseIconSize, "docky.launchpadBaseIconSize"),
        ("launchpadColumnSpacing", PrefKeys.launchpadColumnSpacing, "docky.launchpadColumnSpacing"),
        ("launchpadBackgroundImagePath", PrefKeys.launchpadBackgroundImagePath, "docky.launchpadBackgroundImagePath"),
        ("launchpadBackgroundBlursImage", PrefKeys.launchpadBackgroundBlursImage, "docky.launchpadBackgroundBlursImage"),
        ("launchpadLayoutAxis", PrefKeys.launchpadLayoutAxis, "docky.launchpadLayoutAxis"),
        ("launchpadSortMode", PrefKeys.launchpadSortMode, "docky.launchpadSortMode"),
        ("launchpadShortcut", PrefKeys.launchpadShortcut, "docky.launchpadShortcut"),
        ("enablesWindowSwitcher", PrefKeys.enablesWindowSwitcher, "docky.enablesWindowSwitcher"),
        ("includesMinimizedWindows", PrefKeys.includesMinimizedWindows, "docky.includesMinimizedWindows"),
        ("windowSwitcherShortcut", PrefKeys.windowSwitcherShortcut, "docky.windowSwitcherShortcut"),
        ("showsWindowSwitcherFocusPreview", PrefKeys.showsWindowSwitcherFocusPreview, "docky.showsWindowSwitcherFocusPreview"),
        ("windowSwitcherPreviewMode", PrefKeys.windowSwitcherPreviewMode, "docky.windowSwitcherPreviewMode"),
        ("windowSwitcherLayout", PrefKeys.windowSwitcherLayout, "docky.windowSwitcherLayout"),
        ("switcherMinimizeKeyCode", PrefKeys.switcherMinimizeKeyCode, "docky.switcherMinimizeKeyCode"),
        ("switcherCloseKeyCode", PrefKeys.switcherCloseKeyCode, "docky.switcherCloseKeyCode"),
        ("switcherZoomKeyCode", PrefKeys.switcherZoomKeyCode, "docky.switcherZoomKeyCode"),
        ("pinnedAppBundleIdentifiers", PrefKeys.pinnedAppBundleIdentifiers, "docky.pinnedAppBundleIdentifiers"),
        ("pinnedItems", PrefKeys.pinnedItems, "docky.pinnedItems"),
        ("widgetPlacements", PrefKeys.widgetPlacements, "docky.widgetPlacements"),
        ("appWidgetDisplays", PrefKeys.appWidgetDisplays, "docky.appWidgetDisplays"),
        ("trailingItems", PrefKeys.trailingItems, "docky.trailingItems"),
        ("hasSeenDockEditorHint", PrefKeys.hasSeenDockEditorHint, "docky.hasSeenDockEditorHint"),
        ("photoFrameBookmarks", PrefKeys.photoFrameBookmarks, "docky.photoFrameBookmarks"),
        ("userOverriddenAppearanceKeys", PrefKeys.userOverriddenAppearanceKeys, "docky.userOverriddenAppearanceKeys"),
        ("appearanceOverrideMigrationVersion", PrefKeys.appearanceOverrideMigrationVersion, "docky.appearanceOverrideMigrationVersion"),
    ]

    func testEveryKeyMatchesItsPersistedLiteral() {
        for entry in expected {
            XCTAssertEqual(entry.actual, entry.literal, entry.property)
        }
    }

    func testKeyCountMatchesTheSourceTable() {
        XCTAssertEqual(expected.count, 137)
    }

    func testNoTwoPropertiesShareAStorageKey() {
        let literals = expected.map(\.literal)
        XCTAssertEqual(Set(literals).count, literals.count)
    }

    func testKeysUseTheirOwnNamespacePrefix() {
        for entry in expected {
            XCTAssertTrue(
                entry.literal.hasPrefix("docky.") || entry.literal.hasPrefix("wharf."),
                "\(entry.property): \(entry.literal)"
            )
        }
    }

    func testPrefixesAreNotMixedForTheWharfAdditions() {
        for entry in expected where entry.literal.hasPrefix("wharf.") {
            XCTAssertTrue(
                ["dockContentMode", "windowGrouping", "showsOnlyCurrentScreenWindows", "dockRowCount",
                 "collapsesToButton", "showsMediaProgressOnTiles", "dockStaysBehindBundleIDs",
                 "windowsKeyboardMode", "windowsKeyboardSnipShortcut", "windowsKeyboardExcludedBundleIDs"]
                    .contains(entry.property),
                entry.property
            )
        }
    }

    /// The one key whose property and storage names differ.
    func testWidgetHoverDelayKeepsItsLegacyStorageName() {
        XCTAssertEqual(PrefKeys.widgetHoverPreviewDelay, "docky.widgetHoverGrowDelay")
    }

    func testAppearanceKeysAreAllRealKeys() {
        let literals = Set(expected.map(\.literal)).union([
            DockSettingsService.Keys.tileSize,
            DockSettingsService.Keys.largeSize,
            DockSettingsService.Keys.magnification,
        ])
        XCTAssertEqual(DockyPreferences.appearanceKeys.subtracting(literals), [])
    }

    func testAppearanceKeyCount() {
        XCTAssertEqual(DockyPreferences.appearanceKeys.count, 61)
    }
}
