import XCTest
@testable import Wharf

/// The `effective*` accessors, which are what views actually read. These are the
/// last line of defense for hostile stored values.
///
/// Every test assigns through the setter first, which marks the key as
/// user-overridden. An overridden key ignores the theme layer, so results do not
/// depend on whichever theme is active on the machine running the tests. The
/// theme manager is still consulted (and may create its empty themes directory),
/// so tests that need "no theme" skip when one is active.
final class EffectiveAppearanceTests: DockyPreferencesTestCase {

    private func requireNoActiveTheme() throws {
        try XCTSkipIf(
            ThemeManager.shared.activeManifest != nil,
            "an active theme on this machine changes un-overridden values"
        )
    }

    // MARK: Clamped opacities

    func testHoverOpacityIsBoundedToZeroThroughOne() {
        let prefs = makePrefs()
        for (input, expected) in [(2.0, 1.0), (-1.0, 0.0), (0.4, 0.4), (1e9, 1.0), (-1e9, 0.0)] {
            prefs.tileHoverOpacity = CGFloat(input)
            XCTAssertEqual(prefs.effectiveTileHoverOpacity, CGFloat(expected), accuracy: 1e-9, "\(input)")
        }
    }

    func testHoverBackgroundAndActiveBackgroundOpacitiesAreBounded() {
        let prefs = makePrefs()
        for (input, expected) in [(3.0, 1.0), (-3.0, 0.0), (0.25, 0.25)] {
            prefs.tileHoverBackgroundOpacity = CGFloat(input)
            prefs.tileActiveBackgroundOpacity = CGFloat(input)
            XCTAssertEqual(prefs.effectiveTileHoverBackgroundOpacity, CGFloat(expected), accuracy: 1e-9)
            XCTAssertEqual(prefs.effectiveTileActiveBackgroundOpacity, CGFloat(expected), accuracy: 1e-9)
        }
    }

    func testNaNOpacityStaysInsideTheUnitInterval() {
        let prefs = makePrefs()
        prefs.tileHoverOpacity = .nan
        prefs.tileHoverBackgroundOpacity = .nan
        prefs.tileActiveBackgroundOpacity = .nan
        for value in [prefs.effectiveTileHoverOpacity, prefs.effectiveTileHoverBackgroundOpacity, prefs.effectiveTileActiveBackgroundOpacity] {
            XCTAssertFalse(value.isNaN)
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func testWindowTintOpacityIsBounded() {
        let prefs = makePrefs()
        for (input, expected) in [(5.0, 1.0), (-5.0, 0.0), (0.6, 0.6)] {
            prefs.windowTintOpacity = CGFloat(input)
            XCTAssertEqual(prefs.effectiveWindowTintOpacity, CGFloat(expected), accuracy: 1e-9, "\(input)")
        }
    }

    func testIconShadowOpacityIsBounded() {
        let prefs = makePrefs()
        for (input, expected) in [(5.0, 1.0), (-5.0, 0.0), (0.7, 0.7)] {
            prefs.iconShadowOpacity = CGFloat(input)
            XCTAssertEqual(prefs.effectiveIconShadowOpacity, CGFloat(expected), accuracy: 1e-9, "\(input)")
        }
    }

    func testNonFiniteOpacitiesNeverEscapeTheUnitInterval() {
        let prefs = makePrefs()
        prefs.windowTintOpacity = .nan
        prefs.iconShadowOpacity = .nan
        for value in [prefs.effectiveWindowTintOpacity, prefs.effectiveIconShadowOpacity] {
            XCTExpectFailure("BUG: a NaN opacity passes through min(max(raw, 0), 1) unchanged") {
                XCTAssertFalse(value.isNaN)
            }
        }
    }

    // MARK: Floors

    func testTileIconPaddingFloorsAtZero() {
        let prefs = makePrefs()
        prefs.tileIconPadding = -8
        XCTAssertEqual(prefs.effectiveTileIconPadding, 0)
        prefs.tileIconPadding = 6
        XCTAssertEqual(prefs.effectiveTileIconPadding, 6)
        prefs.tileIconPadding = .nan
        XCTAssertEqual(prefs.effectiveTileIconPadding, 0)
    }

    func testHoverScaleFloorsAtOneTenth() {
        let prefs = makePrefs()
        prefs.tileHoverScale = 0
        XCTAssertEqual(prefs.effectiveTileHoverScale, 0.1, accuracy: 1e-9)
        prefs.tileHoverScale = -4
        XCTAssertEqual(prefs.effectiveTileHoverScale, 0.1, accuracy: 1e-9)
        prefs.tileHoverScale = 1.4
        XCTAssertEqual(prefs.effectiveTileHoverScale, 1.4, accuracy: 1e-9)
        prefs.tileHoverScale = .nan
        XCTAssertEqual(prefs.effectiveTileHoverScale, 0.1, accuracy: 1e-9)
    }

    func testBackgroundCornerRadiiFloorAtZero() {
        let prefs = makePrefs()
        prefs.tileHoverBackgroundCornerRadius = -3
        prefs.tileActiveBackgroundCornerRadius = -3
        XCTAssertEqual(prefs.effectiveTileHoverBackgroundCornerRadius, 0)
        XCTAssertEqual(prefs.effectiveTileActiveBackgroundCornerRadius, 0)
        prefs.tileHoverBackgroundCornerRadius = 9
        XCTAssertEqual(prefs.effectiveTileHoverBackgroundCornerRadius, 9)
    }

    func testPerCornerRadiiFloorAtZero() {
        let prefs = makePrefs()
        prefs.windowCornerRadiusTopLeading = -2
        prefs.windowCornerRadiusTopTrailing = -2
        prefs.windowCornerRadiusBottomLeading = -2
        prefs.windowCornerRadiusBottomTrailing = -2
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusTopLeading, 0)
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusTopTrailing, 0)
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusBottomLeading, 0)
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusBottomTrailing, 0)
    }

    func testUniformCornerRadiusShouldAlsoFloorAtZero() {
        let prefs = makePrefs()
        prefs.windowCornerRadius = -12
        XCTExpectFailure("BUG: effectiveWindowCornerRadius returns a negative radius; every sibling corner accessor floors at 0") {
            XCTAssertGreaterThanOrEqual(prefs.effectiveWindowCornerRadius, 0)
        }
    }

    func testWidgetChromeOverridesFloorAtZeroForEverySpan() {
        let prefs = makePrefs()
        prefs.widget1xContentPadding = -1
        prefs.widget2xContentPadding = -1
        prefs.widget3xContentPadding = -1
        prefs.widget4xContentPadding = -1
        prefs.widget1xCornerRadius = -1
        prefs.widget2xCornerRadius = -1
        prefs.widget3xCornerRadius = -1
        prefs.widget4xCornerRadius = -1
        for span in TileSpan.allCases {
            XCTAssertEqual(prefs.effectiveWidgetContentPadding(for: span), 0, "\(span)")
            XCTAssertEqual(prefs.effectiveWidgetCornerRadius(for: span), 0, "\(span)")
        }
    }

    func testWidgetChromeOverridesPassThroughPerSpan() {
        let prefs = makePrefs()
        prefs.widget1xContentPadding = 1
        prefs.widget2xContentPadding = 2
        prefs.widget3xContentPadding = 3
        prefs.widget4xContentPadding = 4
        prefs.widget1xCornerRadius = 10
        prefs.widget2xCornerRadius = 20
        prefs.widget3xCornerRadius = 30
        prefs.widget4xCornerRadius = 40
        XCTAssertEqual(TileSpan.allCases.compactMap { prefs.effectiveWidgetContentPadding(for: $0) }, [1, 2, 3, 4])
        XCTAssertEqual(TileSpan.allCases.compactMap { prefs.effectiveWidgetCornerRadius(for: $0) }, [10, 20, 30, 40])
    }

    func testWidgetChromeIsNilWhenNeitherUserNorThemeSetsIt() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        for span in TileSpan.allCases {
            XCTAssertNil(prefs.effectiveWidgetContentPadding(for: span))
            XCTAssertNil(prefs.effectiveWidgetCornerRadius(for: span))
            XCTAssertFalse(prefs.effectiveWidgetIgnoresAddedPaddings(for: span))
        }
    }

    func testClearedWidgetChromeNoLongerOverrides() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        prefs.widget3xContentPadding = 5
        XCTAssertEqual(prefs.effectiveWidgetContentPadding(for: .three), 5)
        prefs.widget3xContentPadding = nil
        XCTAssertNil(prefs.effectiveWidgetContentPadding(for: .three))
    }

    // MARK: Pass-through values and the fallback chain

    func testOverriddenRawValuesWinOverTheTheme() {
        let prefs = makePrefs()
        prefs.tileVerticalPadding = 15
        prefs.tileSpacing = 6
        prefs.windowCornerRadius = 19
        prefs.windowContentInsetTop = 9
        prefs.windowContentInsetLeading = 8
        prefs.windowContentInsetBottom = 7
        prefs.windowContentInsetTrailing = 6
        prefs.activeIndicatorOffset = 2
        prefs.activeIndicatorScale = 1.5
        prefs.dividerOffset = 4
        prefs.dividerOpacity = 0.3
        prefs.dividerPaddingFraction = 0.2
        prefs.dividerImageScale = 2
        prefs.windowBorderWidth = 5
        prefs.iconShadowRadius = 11

        XCTAssertEqual(prefs.effectiveTileVerticalPadding, 15)
        XCTAssertEqual(prefs.effectiveTileSpacing, 6)
        XCTAssertEqual(prefs.effectiveWindowCornerRadius, 19)
        XCTAssertEqual(prefs.effectiveWindowContentInsetTop, 9)
        XCTAssertEqual(prefs.effectiveWindowContentInsetLeading, 8)
        XCTAssertEqual(prefs.effectiveWindowContentInsetBottom, 7)
        XCTAssertEqual(prefs.effectiveWindowContentInsetTrailing, 6)
        XCTAssertEqual(prefs.effectiveActiveIndicatorOffset, 2)
        XCTAssertEqual(prefs.effectiveActiveIndicatorScale, 1.5)
        XCTAssertEqual(prefs.effectiveDividerOffset, 4)
        XCTAssertEqual(prefs.effectiveDividerOpacity, 0.3, accuracy: 1e-9)
        XCTAssertEqual(prefs.effectiveDividerPaddingFraction, 0.2, accuracy: 1e-9)
        XCTAssertEqual(prefs.effectiveDividerImageScale, 2)
        XCTAssertEqual(prefs.effectiveWindowBorderWidth, 5)
        XCTAssertEqual(prefs.effectiveIconShadowRadius, 11)
    }

    func testOverriddenEnumsAndFlagsWinOverTheTheme() {
        let prefs = makePrefs()
        prefs.tileClipShape = .circle
        prefs.windowClipShape = .circle
        prefs.windowBackgroundImageMode = .sprite
        prefs.activeIndicatorShape = .underline
        prefs.disablesGlassLook = true
        prefs.showsActivePinnedSeparator = false
        prefs.mirrorsLeftDividerOnRight = true

        XCTAssertEqual(prefs.effectiveTileClipShape, .circle)
        XCTAssertEqual(prefs.effectiveWindowClipShape, .circle)
        XCTAssertEqual(prefs.effectiveWindowBackgroundImageMode, .sprite)
        XCTAssertEqual(prefs.effectiveActiveIndicatorShape, .underline)
        XCTAssertTrue(prefs.effectiveDisablesGlassLook)
        XCTAssertFalse(prefs.effectiveShowsActivePinnedSeparator)
        XCTAssertTrue(prefs.effectiveMirrorsLeftDividerOnRight)
    }

    func testWithNoThemeAndNoOverrideRawDefaultsAreReturned() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        XCTAssertEqual(prefs.effectiveTileVerticalPadding, 8)
        XCTAssertEqual(prefs.effectiveTileSpacing, 0)
        XCTAssertEqual(prefs.effectiveTileHoverOpacity, 1)
        XCTAssertEqual(prefs.effectiveTileHoverScale, 1)
        XCTAssertEqual(prefs.effectiveTileHoverBackgroundCornerRadius, 0)
        XCTAssertEqual(prefs.effectiveWindowCornerRadius, 24)
        XCTAssertEqual(prefs.effectiveWindowContentInsetTop, 2)
        XCTAssertEqual(prefs.effectiveWindowTintOpacity, 0.22, accuracy: 1e-9)
        XCTAssertFalse(prefs.effectiveDisablesGlassLook)
        XCTAssertTrue(prefs.effectiveShowsActivePinnedSeparator)
        XCTAssertNil(prefs.effectiveWindowBorderColor)
        XCTAssertNil(prefs.effectiveIconShadowColor)
        XCTAssertNil(prefs.effectiveDividerColor)
        XCTAssertNil(prefs.effectiveTileHoverBackgroundColor)
    }

    func testPerCornerRadiusFallsBackToTheUniformRadius() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        prefs.windowCornerRadius = 18
        prefs.windowCornerRadiusBottomLeading = 2
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusTopLeading, 18)
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusBottomLeading, 2)
        XCTAssertEqual(prefs.effectiveWindowCornerRadiusTopTrailing, 18)
    }

    func testUnmarkedValueIsIgnoredOnceItsOverrideFlagIsCleared() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        prefs.tileSpacing = 13
        XCTAssertEqual(prefs.effectiveTileSpacing, 13)
        prefs.clearAppearanceOverride(PrefKeys.tileSpacing)
        XCTAssertEqual(prefs.effectiveTileSpacing, 13, "with no theme the raw value is the final fallback")
    }

    // MARK: Colors

    func testOverriddenColorsResolveToTheirNSColors() throws {
        let prefs = makePrefs()
        prefs.windowTintColor = DockColor(red: 1, green: 0, blue: 0)
        prefs.windowBorderColor = DockColor(red: 0, green: 1, blue: 0)
        prefs.iconShadowColor = DockColor(red: 0, green: 0, blue: 1)
        prefs.dividerColor = DockColor(red: 1, green: 1, blue: 0)
        prefs.activeIndicatorColor = DockColor(red: 0, green: 1, blue: 1)
        prefs.tileHoverBackgroundColor = DockColor(red: 0.5, green: 0.5, blue: 0.5)
        prefs.tileActiveBackgroundColor = DockColor(red: 0.2, green: 0.2, blue: 0.2)

        XCTAssertEqual(prefs.effectiveWindowTintColor.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(prefs.effectiveWindowBorderColor).greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(prefs.effectiveIconShadowColor).blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(prefs.effectiveDividerColor).redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(prefs.effectiveActiveIndicatorColor.blueComponent, 1, accuracy: 0.001)
        XCTAssertNotNil(prefs.effectiveTileHoverBackgroundColor)
        XCTAssertNotNil(prefs.effectiveTileActiveBackgroundColor)
    }

    func testExplicitColorsReportTheUserOverrideComponents() throws {
        let prefs = makePrefs()
        prefs.windowTintColor = DockColor(red: 0.1, green: 0.2, blue: 0.3)
        let explicit = try XCTUnwrap(prefs.explicitWindowTintColor)
        XCTAssertEqual(explicit.r, 0.1)
        XCTAssertEqual(explicit.g, 0.2)
        XCTAssertEqual(explicit.b, 0.3)
    }

    func testExplicitColorsAreNilWithoutUserOrTheme() throws {
        try requireNoActiveTheme()
        let prefs = makePrefs()
        XCTAssertNil(prefs.explicitWindowTintColor)
        XCTAssertNil(prefs.explicitActiveIndicatorColor)
        XCTAssertNil(prefs.explicitWindowBorderColor)
        XCTAssertNil(prefs.explicitIconShadowColor)
        XCTAssertNil(prefs.explicitDividerColor)
    }

    func testOutOfRangeColorComponentsNeverTrapWhenResolved() {
        let prefs = makePrefs()
        prefs.windowTintColor = DockColor(red: 9, green: -9, blue: .nan)
        prefs.activeIndicatorColor = DockColor(red: .infinity, green: -.infinity, blue: 1e300)
        _ = prefs.effectiveWindowTintColor
        _ = prefs.effectiveActiveIndicatorColor
    }

    // MARK: Image URLs

    func testImageURLsResolveOnlyForExistingOverriddenFiles() throws {
        try requireNoActiveTheme()
        let directory = makeTempDirectory()
        let file = directory.appendingPathComponent("bg.png")
        try Data([1]).write(to: file)

        let prefs = makePrefs()
        prefs.windowBackgroundImagePath = file.path
        prefs.tileHoverBackgroundImagePath = file.path
        prefs.tileActiveBackgroundImagePath = file.path
        prefs.activeIndicatorImagePath = file.path
        XCTAssertEqual(prefs.effectiveWindowBackgroundImageURL?.path, file.path)
        XCTAssertEqual(prefs.effectiveTileHoverBackgroundImageURL?.path, file.path)
        XCTAssertEqual(prefs.effectiveTileActiveBackgroundImageURL?.path, file.path)
        XCTAssertEqual(prefs.effectiveActiveIndicatorImageURL?.path, file.path)

        let missing = directory.appendingPathComponent("gone.png").path
        prefs.windowBackgroundImagePath = missing
        prefs.tileHoverBackgroundImagePath = missing
        XCTAssertNil(prefs.effectiveWindowBackgroundImageURL)
        XCTAssertNil(prefs.effectiveTileHoverBackgroundImageURL)
    }

    func testHostileImagePathsNeverTrapWhenResolved() {
        let prefs = makePrefs()
        let hostile = ["\0", String(repeating: "a", count: 100_000), "../../..", "/", "~", "file:///etc/hosts"]
        for path in hostile {
            prefs.windowBackgroundImagePath = path
            prefs.tileHoverBackgroundImagePath = path
            prefs.tileActiveBackgroundImagePath = path
            prefs.activeIndicatorImagePath = path
            _ = prefs.effectiveWindowBackgroundImageURL
            _ = prefs.effectiveTileHoverBackgroundImageURL
            _ = prefs.effectiveTileActiveBackgroundImageURL
            _ = prefs.effectiveActiveIndicatorImageURL
        }
    }

    // MARK: Hostile stored layout values

    /// A stored NaN or infinity reaches window frames and SwiftUI layout through
    /// these accessors, none of which sanitizes. AppKit raises on NaN frames.
    func testStoredNonFiniteLayoutValuesShouldNotReachLayout() {
        let keys = [
            PrefKeys.tileVerticalPadding, PrefKeys.tileSpacing, PrefKeys.windowCornerRadius,
            PrefKeys.windowContentInsetTop, PrefKeys.windowContentInsetLeading,
            PrefKeys.windowContentInsetBottom, PrefKeys.windowContentInsetTrailing,
            PrefKeys.activeIndicatorOffset, PrefKeys.dividerOffset,
        ]
        for key in keys {
            defaults.set(Double.nan, forKey: key)
        }
        let prefs = makePrefs()
        let effective: [(String, CGFloat)] = [
            ("tileVerticalPadding", prefs.effectiveTileVerticalPadding),
            ("tileSpacing", prefs.effectiveTileSpacing),
            ("windowCornerRadius", prefs.effectiveWindowCornerRadius),
            ("windowContentInsetTop", prefs.effectiveWindowContentInsetTop),
            ("windowContentInsetLeading", prefs.effectiveWindowContentInsetLeading),
            ("windowContentInsetBottom", prefs.effectiveWindowContentInsetBottom),
            ("windowContentInsetTrailing", prefs.effectiveWindowContentInsetTrailing),
            ("activeIndicatorOffset", prefs.effectiveActiveIndicatorOffset),
            ("dividerOffset", prefs.effectiveDividerOffset),
        ]
        for (name, value) in effective {
            XCTExpectFailure("BUG: a stored NaN reaches layout through effective \(name)") {
                XCTAssertTrue(value.isFinite, name)
            }
        }
    }
}
