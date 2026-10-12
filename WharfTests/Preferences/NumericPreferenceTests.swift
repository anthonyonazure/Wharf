import XCTest
@testable import Wharf

/// One floating-point preference: where it lives, what it defaults to, the
/// bounds `DockyPreferences.init` enforces when loading, and how to read and
/// write it.
private struct NumericSpec {
    let name: String
    let key: String
    let defaultValue: Double
    /// Lower bound applied when the value is loaded from storage.
    let lower: Double?
    /// Upper bound applied when the value is loaded from storage.
    let upper: Double?
    /// True when the property's own setter also clamps (and so can never hold an
    /// out-of-range value in memory).
    let setterClamps: Bool
    let read: (DockyPreferences) -> Double
    let write: (DockyPreferences, Double) -> Void

    init(
        _ name: String,
        _ key: String,
        _ defaultValue: Double,
        lower: Double? = nil,
        upper: Double? = nil,
        setterClamps: Bool = false,
        read: @escaping (DockyPreferences) -> Double,
        write: @escaping (DockyPreferences, Double) -> Void
    ) {
        self.name = name
        self.key = key
        self.defaultValue = defaultValue
        self.lower = lower
        self.upper = upper
        self.setterClamps = setterClamps
        self.read = read
        self.write = write
    }
}

private let numericSpecs: [NumericSpec] = [
    // Unbounded layout values: loaded exactly as stored.
    NumericSpec("tileVerticalPadding", "docky.tileVerticalPadding", 8,
                read: { Double($0.tileVerticalPadding) }, write: { $0.tileVerticalPadding = CGFloat($1) }),
    NumericSpec("tileSpacing", "docky.tileSpacing", 0,
                read: { Double($0.tileSpacing) }, write: { $0.tileSpacing = CGFloat($1) }),
    NumericSpec("tileIconPadding", "docky.tileIconPadding", 0,
                read: { Double($0.tileIconPadding) }, write: { $0.tileIconPadding = CGFloat($1) }),
    NumericSpec("windowCornerRadius", "docky.windowCornerRadius", 24,
                read: { Double($0.windowCornerRadius) }, write: { $0.windowCornerRadius = CGFloat($1) }),
    NumericSpec("windowContentInsetTop", "docky.windowContentInsetTop", 2,
                read: { Double($0.windowContentInsetTop) }, write: { $0.windowContentInsetTop = CGFloat($1) }),
    NumericSpec("windowContentInsetLeading", "docky.windowContentInsetLeading", 2,
                read: { Double($0.windowContentInsetLeading) }, write: { $0.windowContentInsetLeading = CGFloat($1) }),
    NumericSpec("windowContentInsetBottom", "docky.windowContentInsetBottom", 2,
                read: { Double($0.windowContentInsetBottom) }, write: { $0.windowContentInsetBottom = CGFloat($1) }),
    NumericSpec("windowContentInsetTrailing", "docky.windowContentInsetTrailing", 2,
                read: { Double($0.windowContentInsetTrailing) }, write: { $0.windowContentInsetTrailing = CGFloat($1) }),
    NumericSpec("windowTintOpacity", "docky.windowTintOpacity", 0.22,
                read: { Double($0.windowTintOpacity) }, write: { $0.windowTintOpacity = CGFloat($1) }),
    NumericSpec("activeIndicatorOffset", "docky.activeIndicatorOffset", 0,
                read: { Double($0.activeIndicatorOffset) }, write: { $0.activeIndicatorOffset = CGFloat($1) }),
    NumericSpec("dividerOffset", "docky.dividerOffset", 0,
                read: { Double($0.dividerOffset) }, write: { $0.dividerOffset = CGFloat($1) }),

    // Delays: floor of zero at load. Setters clamp too.
    NumericSpec("autohideWindowDelay", "docky.autohideWindowDelay", 0.5, lower: 0, setterClamps: true,
                read: { $0.autohideWindowDelay }, write: { $0.autohideWindowDelay = $1 }),
    NumericSpec("fullscreenRevealDelay", "docky.fullscreenRevealDelay", 0.5, lower: 0, setterClamps: true,
                read: { $0.fullscreenRevealDelay }, write: { $0.fullscreenRevealDelay = $1 }),
    NumericSpec("windowPreviewHoverDelay", "docky.windowPreviewHoverDelay", 1.0, lower: 0, setterClamps: true,
                read: { $0.windowPreviewHoverDelay }, write: { $0.windowPreviewHoverDelay = $1 }),
    NumericSpec("widgetHoverPreviewDelay", "docky.widgetHoverGrowDelay", 1.0, lower: 0, setterClamps: true,
                read: { $0.widgetHoverPreviewDelay }, write: { $0.widgetHoverPreviewDelay = $1 }),

    // Bounded at load, not in the setter.
    NumericSpec("autohideAnimationDuration", "docky.autohideAnimationDuration", 0.22, lower: 0, upper: 1, setterClamps: true,
                read: { $0.autohideAnimationDuration }, write: { $0.autohideAnimationDuration = $1 }),
    NumericSpec("activeIndicatorScale", "docky.activeIndicatorScale", 1, lower: 0.25,
                read: { Double($0.activeIndicatorScale) }, write: { $0.activeIndicatorScale = CGFloat($1) }),
    NumericSpec("dividerPaddingFraction", "docky.dividerPaddingFraction", 0.25, lower: 0, upper: 0.5,
                read: { Double($0.dividerPaddingFraction) }, write: { $0.dividerPaddingFraction = CGFloat($1) }),
    NumericSpec("dividerImageScale", "docky.dividerImageScale", 1, lower: 0.25,
                read: { Double($0.dividerImageScale) }, write: { $0.dividerImageScale = CGFloat($1) }),
    NumericSpec("dividerOpacity", "docky.dividerOpacity", 1, lower: 0, upper: 1,
                read: { Double($0.dividerOpacity) }, write: { $0.dividerOpacity = CGFloat($1) }),
    NumericSpec("windowBorderWidth", "docky.windowBorderWidth", 1, lower: 0,
                read: { Double($0.windowBorderWidth) }, write: { $0.windowBorderWidth = CGFloat($1) }),
    NumericSpec("iconShadowRadius", "docky.iconShadowRadius", 4, lower: 0,
                read: { Double($0.iconShadowRadius) }, write: { $0.iconShadowRadius = CGFloat($1) }),
    NumericSpec("iconShadowOpacity", "docky.iconShadowOpacity", 0.5, lower: 0, upper: 1,
                read: { Double($0.iconShadowOpacity) }, write: { $0.iconShadowOpacity = CGFloat($1) }),

    // Launchpad.
    NumericSpec("launchpadOverlayTransparency", "docky.launchpadOverlayTransparency", 0.75, lower: 0, upper: 1, setterClamps: true,
                read: { Double($0.launchpadOverlayTransparency) }, write: { $0.launchpadOverlayTransparency = CGFloat($1) }),
    NumericSpec("launchpadBaseIconSize", "docky.launchpadBaseIconSize", 128, lower: 48, upper: 192, setterClamps: true,
                read: { Double($0.launchpadBaseIconSize) }, write: { $0.launchpadBaseIconSize = CGFloat($1) }),
    NumericSpec("launchpadColumnSpacing", "docky.launchpadColumnSpacing", 96, lower: 0, upper: 96, setterClamps: true,
                read: { Double($0.launchpadColumnSpacing) }, write: { $0.launchpadColumnSpacing = CGFloat($1) }),
]

/// Keys whose load-time clamp is written with `max(stored, bound)` ordering, so a
/// stored NaN survives it. Swift's `max(nan, 0)` returns NaN.
private let nanLeakingNames: Set<String> = [
    "autohideWindowDelay",
    "fullscreenRevealDelay",
    "windowPreviewHoverDelay",
    "widgetHoverPreviewDelay",
    "autohideAnimationDuration",
    "dividerPaddingFraction",
    "dividerOpacity",
    "iconShadowOpacity",
    "launchpadOverlayTransparency",
]

final class NumericPreferenceTests: DockyPreferencesTestCase {
    private var clampedSpecs: [NumericSpec] {
        numericSpecs.filter { $0.lower != nil || $0.upper != nil }
    }

    func testSpecTableCoversEveryDocumentedKey() {
        // 11 unbounded + 4 delays + 1 duration + 7 bounded appearance + 3 launchpad.
        XCTAssertEqual(numericSpecs.count, 26)
        XCTAssertEqual(Set(numericSpecs.map(\.key)).count, numericSpecs.count, "duplicate key in spec table")
    }

    func testSpecKeysMatchTheSourceKeyTable() {
        let sourceKeys: [String: String] = [
            "tileVerticalPadding": PrefKeys.tileVerticalPadding,
            "autohideWindowDelay": PrefKeys.autohideWindowDelay,
            "autohideAnimationDuration": PrefKeys.autohideAnimationDuration,
            "fullscreenRevealDelay": PrefKeys.fullscreenRevealDelay,
            "windowPreviewHoverDelay": PrefKeys.windowPreviewHoverDelay,
            "widgetHoverPreviewDelay": PrefKeys.widgetHoverPreviewDelay,
            "launchpadBaseIconSize": PrefKeys.launchpadBaseIconSize,
        ]
        for (name, key) in sourceKeys {
            XCTAssertEqual(numericSpecs.first { $0.name == name }?.key, key, name)
        }
    }

    // MARK: Missing and wrong-typed values

    func testMissingKeyYieldsDefault() {
        let prefs = makePrefs()
        for spec in numericSpecs {
            XCTAssertEqual(spec.read(prefs), spec.defaultValue, accuracy: 1e-9, spec.name)
        }
    }

    func testWrongTypeFallsBackToDefault() {
        let wrongValues: [Any] = ["abc", "12", "", Data([0x01, 0x02]), ["a", "b"], ["k": "v"]]
        for spec in numericSpecs {
            for wrong in wrongValues {
                defaults.set(wrong, forKey: spec.key)
                XCTAssertEqual(
                    spec.read(makePrefs()), spec.defaultValue, accuracy: 1e-9,
                    "\(spec.name) with \(type(of: wrong))"
                )
                defaults.removeObject(forKey: spec.key)
            }
        }
    }

    // MARK: Range handling at load

    func testInRangeValuesRoundTripThroughInit() {
        let candidates: [Double] = [0, 0.25, 0.3, 0.5, 1, 2.5, 10, 48, 60.5, 96, 100, 192]
        for spec in numericSpecs {
            for candidate in candidates {
                if let lower = spec.lower, candidate < lower { continue }
                if let upper = spec.upper, candidate > upper { continue }
                defaults.set(candidate, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), candidate, accuracy: 1e-9, "\(spec.name)=\(candidate)")
            }
        }
    }

    func testBelowRangeClampsToLowerBound() {
        for spec in clampedSpecs {
            guard let lower = spec.lower else { continue }
            for hostile in [lower - 0.001, lower - 5, -1, -1e9, -Double.greatestFiniteMagnitude, -Double.infinity] {
                defaults.set(hostile, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), lower, accuracy: 1e-9, "\(spec.name)=\(hostile)")
            }
        }
    }

    func testAboveRangeClampsToUpperBound() {
        for spec in clampedSpecs {
            guard let upper = spec.upper else { continue }
            for hostile in [upper + 0.001, upper + 5, 1e9, Double.greatestFiniteMagnitude, Double.infinity] {
                defaults.set(hostile, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), upper, accuracy: 1e-9, "\(spec.name)=\(hostile)")
            }
        }
    }

    func testBoundariesThemselvesAreAccepted() {
        for spec in clampedSpecs {
            for bound in [spec.lower, spec.upper].compactMap({ $0 }) {
                defaults.set(bound, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), bound, accuracy: 1e-9, "\(spec.name)=\(bound)")
            }
        }
    }

    func testUnboundedKeysStoreNegativeAndHugeValuesWithoutTrapping() {
        for spec in numericSpecs where spec.lower == nil && spec.upper == nil {
            for value in [-50.0, -1e9, 1e9, 1e300] {
                defaults.set(value, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), value, spec.name)
            }
        }
    }

    func testInfinitiesNeverTrap() {
        for spec in numericSpecs {
            for value in [Double.infinity, -Double.infinity] {
                defaults.set(value, forKey: spec.key)
                let loaded = spec.read(makePrefs())
                XCTAssertFalse(loaded.isNaN, "\(spec.name)=\(value)")
                if let upper = spec.upper, value == .infinity { XCTAssertEqual(loaded, upper, spec.name) }
                if let lower = spec.lower, value == -.infinity { XCTAssertEqual(loaded, lower, spec.name) }
            }
        }
    }

    func testNaNNeverTrapsAnyKey() {
        for spec in numericSpecs {
            defaults.set(Double.nan, forKey: spec.key)
            _ = spec.read(makePrefs())
        }
    }

    func testNaNIsRejectedByKeysWhoseClampOrderSurvivesIt() {
        for spec in clampedSpecs where !nanLeakingNames.contains(spec.name) {
            defaults.set(Double.nan, forKey: spec.key)
            XCTAssertFalse(spec.read(makePrefs()).isNaN, spec.name)
        }
    }

    /// A stored NaN should never reach a timer or a layout calculation. These
    /// keys clamp with `max(stored, bound)`, which returns NaN for a NaN `stored`.
    func testStoredNaNCannotReachTheLaunchpadLayoutMath() {
        // The Launchpad grid does `Int(iconSize / ...)`, which traps on NaN.
        for key in [PrefKeys.launchpadBaseIconSize, PrefKeys.launchpadColumnSpacing] {
            defaults.set(Double.nan, forKey: key)
        }
        let prefs = makePrefs()
        XCTAssertEqual(prefs.launchpadBaseIconSize, 48)
        XCTAssertEqual(prefs.launchpadColumnSpacing, 0)
    }

    func testNaNLeaksThroughLoadTimeClampForSomeKeys() {
        for spec in clampedSpecs where nanLeakingNames.contains(spec.name) {
            defaults.set(Double.nan, forKey: spec.key)
            let loaded = spec.read(makePrefs())
            XCTExpectFailure("BUG: \(spec.name) loads a stored NaN unclamped (max(nan, bound) returns nan)") {
                XCTAssertFalse(loaded.isNaN, spec.name)
            }
        }
    }

    // MARK: Setters

    func testSetterPersistsAndSurvivesReload() {
        for spec in numericSpecs {
            let candidates = [(spec.lower ?? 0) + 0.5, 3.5, (spec.lower ?? 0) + 0.2]
            guard let inRange = candidates.first(where: {
                abs($0 - spec.defaultValue) > 1e-9 && $0 >= (spec.lower ?? -.infinity) && $0 <= (spec.upper ?? .infinity)
            }) else {
                XCTFail("no usable in-range value for \(spec.name)")
                continue
            }
            let prefs = makePrefs()
            spec.write(prefs, inRange)
            XCTAssertEqual(spec.read(prefs), inRange, accuracy: 1e-9, spec.name)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Double, inRange, spec.name)
            XCTAssertEqual(spec.read(reload()), inRange, accuracy: 1e-9, spec.name)
        }
    }

    func testSettingTheSameValueDoesNotWriteTheKey() {
        for spec in numericSpecs {
            let prefs = makePrefs()
            spec.write(prefs, spec.defaultValue)
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
        }
    }

    func testSettersThatClampKeepOutOfRangeValuesOutOfMemory() {
        for spec in numericSpecs where spec.setterClamps {
            if let lower = spec.lower {
                let prefs = makePrefs()
                spec.write(prefs, lower - 10)
                XCTAssertEqual(spec.read(prefs), lower, accuracy: 1e-9, "\(spec.name) below")
            }
            if let upper = spec.upper {
                let prefs = makePrefs()
                spec.write(prefs, upper + 10)
                XCTAssertEqual(spec.read(prefs), upper, accuracy: 1e-9, "\(spec.name) above")
            }
        }
    }

    func testClampingSetterPersistsTheClampedValue() {
        for spec in numericSpecs where spec.setterClamps {
            guard let lower = spec.lower else { continue }
            let prefs = makePrefs()
            spec.write(prefs, lower - 10)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Double, lower, spec.name)
            XCTAssertEqual(spec.read(reload()), lower, accuracy: 1e-9, spec.name)
        }
    }

    func testSettersThatDoNotClampKeepRawValueInMemory() {
        for spec in numericSpecs where !spec.setterClamps && (spec.lower != nil || spec.upper != nil) {
            let hostile = (spec.lower ?? 0) - 1
            let prefs = makePrefs()
            spec.write(prefs, hostile)
            XCTAssertEqual(spec.read(prefs), hostile, accuracy: 1e-9, spec.name)
        }
    }

    /// The value a user sees in-session should equal the one they get after a
    /// relaunch. Setters that skip the clamp diverge from the loader.
    func testSetterAndLoaderAgreeOnOutOfRangeValues() {
        for spec in numericSpecs where !spec.setterClamps && (spec.lower != nil || spec.upper != nil) {
            let hostile = (spec.lower ?? 0) - 1
            let prefs = makePrefs()
            spec.write(prefs, hostile)
            let inSession = spec.read(prefs)
            let afterRelaunch = spec.read(reload())
            XCTExpectFailure("BUG: \(spec.name) setter stores \(hostile) while the loader clamps it to \(afterRelaunch)") {
                XCTAssertEqual(inSession, afterRelaunch, accuracy: 1e-9, spec.name)
            }
        }
    }

    /// Regression: the three launchpad clamps used `max(value, bound)`, which
    /// returns NaN for NaN, so their re-assignment inside `didSet` recursed until
    /// the stack overflowed. Bound-first ordering turns NaN into the bound.
    func testNaNAssignedToClampingSettersFallsToTheLowerBound() {
        for spec in numericSpecs where spec.setterClamps {
            let prefs = makePrefs()
            spec.write(prefs, .nan)
            let value = spec.read(prefs)
            XCTAssertFalse(value.isNaN, spec.name)
            XCTAssertEqual(value, spec.lower ?? 0, accuracy: 1e-9, spec.name)
        }
    }

    func testInfinityAssignedToClampingSettersIsBounded() {
        for spec in numericSpecs where spec.setterClamps {
            guard let upper = spec.upper else { continue }
            let prefs = makePrefs()
            spec.write(prefs, .infinity)
            XCTAssertEqual(spec.read(prefs), upper, spec.name)
        }
    }
}
