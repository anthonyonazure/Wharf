import CoreGraphics
import Foundation
@testable import Wharf

/// One preference, one non-default assignment, and a way to read the value back
/// as a comparable string. Drives the override-layer, reset and persistence
/// tests across every stored preference at once.
///
/// Deliberately absent: `windowPosition`, `opensAtLogin` and `hidesSystemDock`.
/// Their setters move or hide the real system Dock or register a login item.
struct PreferenceMutation {
    let name: String
    /// The `UserDefaults` key the setter writes.
    let key: String
    let mutate: (DockyPreferences) -> Void
    /// Sets the property back to "unset" (`nil`) when it is optional.
    let clear: ((DockyPreferences) -> Void)?
    let read: (DockyPreferences) -> String

    var isAppearance: Bool { DockyPreferences.appearanceKeys.contains(key) }
}

private func value<T>(
    _ name: String,
    _ key: String,
    _ path: ReferenceWritableKeyPath<DockyPreferences, T>,
    _ newValue: T
) -> PreferenceMutation {
    PreferenceMutation(
        name: name, key: key,
        mutate: { $0[keyPath: path] = newValue },
        clear: nil,
        read: { String(describing: $0[keyPath: path]) }
    )
}

private func optional<T>(
    _ name: String,
    _ key: String,
    _ path: ReferenceWritableKeyPath<DockyPreferences, T?>,
    _ newValue: T
) -> PreferenceMutation {
    PreferenceMutation(
        name: name, key: key,
        mutate: { $0[keyPath: path] = newValue },
        clear: { $0[keyPath: path] = nil },
        read: { String(describing: $0[keyPath: path]) }
    )
}

enum PreferenceMutations {
    private static let red = DockColor(red: 1, green: 0, blue: 0)

    static let all: [PreferenceMutation] = appearance + behavior

    static let appearance: [PreferenceMutation] = [
        value("disablesGlassLook", PrefKeys.disablesGlassLook, \.disablesGlassLook, true),
        value("tileVerticalPadding", PrefKeys.tileVerticalPadding, \.tileVerticalPadding, 12),
        value("tileSpacing", PrefKeys.tileSpacing, \.tileSpacing, 5),
        value("tileClipShape", PrefKeys.tileClipShape, \.tileClipShape, .circle),
        value("tileIconPadding", PrefKeys.tileIconPadding, \.tileIconPadding, 3),
        optional("tileHoverOpacity", PrefKeys.tileHoverOpacity, \.tileHoverOpacity, 0.5),
        optional("tileHoverScale", PrefKeys.tileHoverScale, \.tileHoverScale, 1.2),
        optional("tileHoverBackgroundColor", PrefKeys.tileHoverBackgroundColor, \.tileHoverBackgroundColor, red),
        optional("tileHoverBackgroundImagePath", PrefKeys.tileHoverBackgroundImagePath, \.tileHoverBackgroundImagePath, "/tmp/h.png"),
        optional("tileHoverBackgroundOpacity", PrefKeys.tileHoverBackgroundOpacity, \.tileHoverBackgroundOpacity, 0.4),
        optional("tileHoverBackgroundCornerRadius", PrefKeys.tileHoverBackgroundCornerRadius, \.tileHoverBackgroundCornerRadius, 6),
        optional("tileActiveBackgroundColor", PrefKeys.tileActiveBackgroundColor, \.tileActiveBackgroundColor, red),
        optional("tileActiveBackgroundImagePath", PrefKeys.tileActiveBackgroundImagePath, \.tileActiveBackgroundImagePath, "/tmp/a.png"),
        optional("tileActiveBackgroundOpacity", PrefKeys.tileActiveBackgroundOpacity, \.tileActiveBackgroundOpacity, 0.3),
        optional("tileActiveBackgroundCornerRadius", PrefKeys.tileActiveBackgroundCornerRadius, \.tileActiveBackgroundCornerRadius, 5),
        optional("widget1xContentPadding", PrefKeys.widget1xContentPadding, \.widget1xContentPadding, 4),
        optional("widget1xCornerRadius", PrefKeys.widget1xCornerRadius, \.widget1xCornerRadius, 4),
        optional("widget2xContentPadding", PrefKeys.widget2xContentPadding, \.widget2xContentPadding, 4),
        optional("widget2xCornerRadius", PrefKeys.widget2xCornerRadius, \.widget2xCornerRadius, 4),
        optional("widget3xContentPadding", PrefKeys.widget3xContentPadding, \.widget3xContentPadding, 4),
        optional("widget3xCornerRadius", PrefKeys.widget3xCornerRadius, \.widget3xCornerRadius, 4),
        optional("widget4xContentPadding", PrefKeys.widget4xContentPadding, \.widget4xContentPadding, 4),
        optional("widget4xCornerRadius", PrefKeys.widget4xCornerRadius, \.widget4xCornerRadius, 4),
        value("windowCornerRadius", PrefKeys.windowCornerRadius, \.windowCornerRadius, 10),
        optional("windowCornerRadiusTopLeading", PrefKeys.windowCornerRadiusTopLeading, \.windowCornerRadiusTopLeading, 3),
        optional("windowCornerRadiusTopTrailing", PrefKeys.windowCornerRadiusTopTrailing, \.windowCornerRadiusTopTrailing, 3),
        optional("windowCornerRadiusBottomLeading", PrefKeys.windowCornerRadiusBottomLeading, \.windowCornerRadiusBottomLeading, 3),
        optional("windowCornerRadiusBottomTrailing", PrefKeys.windowCornerRadiusBottomTrailing, \.windowCornerRadiusBottomTrailing, 3),
        value("windowContentInsetTop", PrefKeys.windowContentInsetTop, \.windowContentInsetTop, 7),
        value("windowContentInsetLeading", PrefKeys.windowContentInsetLeading, \.windowContentInsetLeading, 7),
        value("windowContentInsetBottom", PrefKeys.windowContentInsetBottom, \.windowContentInsetBottom, 7),
        value("windowContentInsetTrailing", PrefKeys.windowContentInsetTrailing, \.windowContentInsetTrailing, 7),
        value("windowClipShape", PrefKeys.windowClipShape, \.windowClipShape, .circle),
        optional("windowTintColor", PrefKeys.windowTintColor, \.windowTintColor, red),
        value("windowTintOpacity", PrefKeys.windowTintOpacity, \.windowTintOpacity, 0.5),
        optional("windowBackgroundImagePath", PrefKeys.windowBackgroundImagePath, \.windowBackgroundImagePath, "/tmp/bg.png"),
        value("windowBackgroundImageMode", PrefKeys.windowBackgroundImageMode, \.windowBackgroundImageMode, .sprite),
        value("activeIndicatorShape", PrefKeys.activeIndicatorShape, \.activeIndicatorShape, .pill),
        optional("activeIndicatorImagePath", PrefKeys.activeIndicatorImagePath, \.activeIndicatorImagePath, "/tmp/i.png"),
        optional("activeIndicatorColor", PrefKeys.activeIndicatorColor, \.activeIndicatorColor, red),
        value("activeIndicatorOffset", PrefKeys.activeIndicatorOffset, \.activeIndicatorOffset, 3),
        value("activeIndicatorScale", PrefKeys.activeIndicatorScale, \.activeIndicatorScale, 2),
        optional("dividerImagePath", PrefKeys.dividerImagePath, \.dividerImagePath, "/tmp/d.png"),
        optional("leftDividerImagePath", PrefKeys.leftDividerImagePath, \.leftDividerImagePath, "/tmp/l.png"),
        optional("rightDividerImagePath", PrefKeys.rightDividerImagePath, \.rightDividerImagePath, "/tmp/r.png"),
        value("mirrorsLeftDividerOnRight", PrefKeys.mirrorsLeftDividerOnRight, \.mirrorsLeftDividerOnRight, true),
        value("dividerPaddingFraction", PrefKeys.dividerPaddingFraction, \.dividerPaddingFraction, 0.1),
        value("dividerImageScale", PrefKeys.dividerImageScale, \.dividerImageScale, 2),
        value("dividerOffset", PrefKeys.dividerOffset, \.dividerOffset, 2),
        value("dividerOpacity", PrefKeys.dividerOpacity, \.dividerOpacity, 0.5),
        optional("dividerColor", PrefKeys.dividerColor, \.dividerColor, red),
        optional("windowBorderColor", PrefKeys.windowBorderColor, \.windowBorderColor, red),
        value("windowBorderWidth", PrefKeys.windowBorderWidth, \.windowBorderWidth, 3),
        optional("iconShadowColor", PrefKeys.iconShadowColor, \.iconShadowColor, red),
        value("iconShadowRadius", PrefKeys.iconShadowRadius, \.iconShadowRadius, 9),
        value("iconShadowOpacity", PrefKeys.iconShadowOpacity, \.iconShadowOpacity, 0.9),
        value("showsActivePinnedSeparator", PrefKeys.showsActivePinnedSeparator, \.showsActivePinnedSeparator, false),
    ]

    static let behavior: [PreferenceMutation] = [
        value("windowDisplayTarget", PrefKeys.windowDisplayTarget, \.windowDisplayTarget, .allDisplays),
        value("windowSpaceBehavior", PrefKeys.windowSpaceBehavior, \.windowSpaceBehavior, .activeSpace),
        value("autohidesWindow", PrefKeys.autohidesWindow, \.autohidesWindow, true),
        value("dockContentMode", PrefKeys.dockContentMode, \.dockContentMode, .taskbar),
        value("windowGrouping", PrefKeys.windowGrouping, \.windowGrouping, .never),
        value("showsOnlyCurrentScreenWindows", PrefKeys.showsOnlyCurrentScreenWindows, \.showsOnlyCurrentScreenWindows, true),
        value("dockRowCount", PrefKeys.dockRowCount, \.dockRowCount, 3),
        value("collapsesToButton", PrefKeys.collapsesToButton, \.collapsesToButton, true),
        value("showsMediaProgressOnTiles", PrefKeys.showsMediaProgressOnTiles, \.showsMediaProgressOnTiles, false),
        value("dockStaysBehindBundleIDs", PrefKeys.dockStaysBehindBundleIDs, \.dockStaysBehindBundleIDs, ["a.b"]),
        value("windowsKeyboardMode", PrefKeys.windowsKeyboardMode, \.windowsKeyboardMode, true),
        value("windowsKeyboardSnipShortcut", PrefKeys.windowsKeyboardSnipShortcut, \.windowsKeyboardSnipShortcut, false),
        value("windowsKeyboardExcludedBundleIDs", PrefKeys.windowsKeyboardExcludedBundleIDs, \.windowsKeyboardExcludedBundleIDs, ["c.d"]),
        value("showsAppBadges", PrefKeys.showsAppBadges, \.showsAppBadges, false),
        value("folderBadgeMode", PrefKeys.folderBadgeMode, \.folderBadgeMode, .perApp),
        value("folderBadgePreviewStyle", PrefKeys.folderBadgePreviewStyle, \.folderBadgePreviewStyle, .number),
        value("autohideWindowDelay", PrefKeys.autohideWindowDelay, \.autohideWindowDelay, 2),
        value("autohideAnimationDuration", PrefKeys.autohideAnimationDuration, \.autohideAnimationDuration, 0.6),
        value("fullscreenRevealDelay", PrefKeys.fullscreenRevealDelay, \.fullscreenRevealDelay, 2),
        value("windowPreviewHoverDelay", PrefKeys.windowPreviewHoverDelay, \.windowPreviewHoverDelay, 3),
        value("windowPreviewLayout", PrefKeys.windowPreviewLayout, \.windowPreviewLayout, .list),
        value("maximizedWindowBehavior", PrefKeys.maximizedWindowBehavior, \.maximizedWindowBehavior, .hideDocky),
        value("overflowBehavior", PrefKeys.overflowBehavior, \.overflowBehavior, .scroll),
        value("windowAxisSizing", PrefKeys.windowAxisSizing, \.windowAxisSizing, .fullAxis),
        value("enablesWidgetHoverPreview", PrefKeys.enablesWidgetHoverPreview, \.enablesWidgetHoverPreview, false),
        value("widgetHoverPreviewDelay", PrefKeys.widgetHoverPreviewDelay, \.widgetHoverPreviewDelay, 2),
        value("showsRunningApps", PrefKeys.showsRunningApps, \.showsRunningApps, false),
        value("appTileFrontmostClickBehavior", PrefKeys.appTileFrontmostClickBehavior, \.appTileFrontmostClickBehavior, .hide),
        value("showsMinimizedWindows", PrefKeys.showsMinimizedWindows, \.showsMinimizedWindows, false),
        value("hidesDuringFullscreen", PrefKeys.hidesDuringFullscreen, \.hidesDuringFullscreen, false),
        value("enablesShelveMode", PrefKeys.enablesShelveMode, \.enablesShelveMode, true),
        value("shelveHidesFinder", PrefKeys.shelveHidesFinder, \.shelveHidesFinder, false),
        value("shelveHidesTrash", PrefKeys.shelveHidesTrash, \.shelveHidesTrash, false),
        value("hidesRecentApps", PrefKeys.hidesRecentApps, \.hidesRecentApps, true),
        value("hidesProfileStrip", PrefKeys.hidesProfileStrip, \.hidesProfileStrip, true),
        optional("launchpadIconPath", PrefKeys.launchpadIconPath, \.launchpadIconPath, "/tmp/lp.png"),
        optional("launchpadIconPaddingFraction", PrefKeys.launchpadIconPaddingFraction, \.launchpadIconPaddingFraction, 0.2),
        optional("startMenuIconPath", PrefKeys.startMenuIconPath, \.startMenuIconPath, "/tmp/sm.png"),
        optional("startMenuIconPaddingFraction", PrefKeys.startMenuIconPaddingFraction, \.startMenuIconPaddingFraction, 0.2),
        value("showsGroupedOpenedAppsInDock", PrefKeys.showsGroupedOpenedAppsInDock, \.showsGroupedOpenedAppsInDock, false),
        value("showsGroupedOpenedAppsBackdrop", PrefKeys.showsGroupedOpenedAppsBackdrop, \.showsGroupedOpenedAppsBackdrop, false),
        value("enablesLaunchpadOverlay", PrefKeys.enablesLaunchpadOverlay, \.enablesLaunchpadOverlay, false),
        value("enablesStartMenuOverlay", PrefKeys.enablesStartMenuOverlay, \.enablesStartMenuOverlay, false),
        value("opensStartMenuFromFinderTile", PrefKeys.opensStartMenuFromFinderTile, \.opensStartMenuFromFinderTile, true),
        value("launchpadOverlayTransparency", PrefKeys.launchpadOverlayTransparency, \.launchpadOverlayTransparency, 0.5),
        value("launchpadGridColumnCount", PrefKeys.launchpadGridColumnCount, \.launchpadGridColumnCount, 9),
        value("launchpadGridRowCount", PrefKeys.launchpadGridRowCount, \.launchpadGridRowCount, 3),
        value("launchpadBaseIconSize", PrefKeys.launchpadBaseIconSize, \.launchpadBaseIconSize, 100),
        value("launchpadColumnSpacing", PrefKeys.launchpadColumnSpacing, \.launchpadColumnSpacing, 40),
        optional("launchpadBackgroundImagePath", PrefKeys.launchpadBackgroundImagePath, \.launchpadBackgroundImagePath, "/tmp/lbg.png"),
        value("launchpadBackgroundBlursImage", PrefKeys.launchpadBackgroundBlursImage, \.launchpadBackgroundBlursImage, false),
        value("launchpadLayoutAxis", PrefKeys.launchpadLayoutAxis, \.launchpadLayoutAxis,
              LaunchpadLayoutAxis.defaultForCurrentOS == .vertical ? .horizontal : .vertical),
        value("launchpadSortMode", PrefKeys.launchpadSortMode, \.launchpadSortMode, .name),
        value("launchpadShortcut", PrefKeys.launchpadShortcut, \.launchpadShortcut, KeyboardShortcut(keyCode: 37, modifierFlags: [.command])),
        value("enablesWindowSwitcher", PrefKeys.enablesWindowSwitcher, \.enablesWindowSwitcher, false),
        value("includesMinimizedWindows", PrefKeys.includesMinimizedWindows, \.includesMinimizedWindows, false),
        value("windowSwitcherShortcut", PrefKeys.windowSwitcherShortcut, \.windowSwitcherShortcut, KeyboardShortcut(keyCode: 50, modifierFlags: [.control])),
        value("showsWindowSwitcherFocusPreview", PrefKeys.showsWindowSwitcherFocusPreview, \.showsWindowSwitcherFocusPreview, false),
        value("windowSwitcherPreviewMode", PrefKeys.windowSwitcherPreviewMode, \.windowSwitcherPreviewMode, .instantFocus),
        value("windowSwitcherLayout", PrefKeys.windowSwitcherLayout, \.windowSwitcherLayout, .list),
        value("switcherMinimizeKeyCode", PrefKeys.switcherMinimizeKeyCode, \.switcherMinimizeKeyCode, 99),
        value("switcherCloseKeyCode", PrefKeys.switcherCloseKeyCode, \.switcherCloseKeyCode, 99),
        value("switcherZoomKeyCode", PrefKeys.switcherZoomKeyCode, \.switcherZoomKeyCode, 99),
        value("hasSeenDockEditorHint", PrefKeys.hasSeenDockEditorHint, \.hasSeenDockEditorHint, true),
        value("hiddenAppBundleIdentifiers", PrefKeys.hiddenAppBundleIdentifiers, \.hiddenAppBundleIdentifiers, ["x.hidden"]),
        value("appIconOverrides", PrefKeys.appIconOverrides, \.appIconOverrides, [AppIconOverride(bundleIdentifier: "a", iconPath: "/i")]),
        value("trashIconOverrides", PrefKeys.trashIconOverrides, \.trashIconOverrides, [TrashIconOverride(state: .empty, iconPath: "/i")]),
        value("folderIconOverrides", PrefKeys.folderIconOverrides, \.folderIconOverrides, [FolderIconOverride(folderPath: "/f", iconPath: "/i")]),
        value("widgetHoverPreviewSpans", PrefKeys.widgetHoverPreviewSpans, \.widgetHoverPreviewSpans, [.one]),
    ]
}
