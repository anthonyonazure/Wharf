import XCTest
@testable import Wharf

private struct BoolSpec {
    let name: String
    let key: String
    let defaultValue: Bool
    let read: (DockyPreferences) -> Bool
    /// `nil` for settings whose setter reaches a real machine service.
    let write: ((DockyPreferences, Bool) -> Void)?
}

private let boolSpecs: [BoolSpec] = [
    BoolSpec(name: "disablesGlassLook", key: "docky.disablesGlassLook", defaultValue: false,
             read: { $0.disablesGlassLook }, write: { $0.disablesGlassLook = $1 }),
    BoolSpec(name: "autohidesWindow", key: "docky.autohidesWindow", defaultValue: false,
             read: { $0.autohidesWindow }, write: { $0.autohidesWindow = $1 }),
    BoolSpec(name: "showsOnlyCurrentScreenWindows", key: "wharf.showsOnlyCurrentScreenWindows", defaultValue: false,
             read: { $0.showsOnlyCurrentScreenWindows }, write: { $0.showsOnlyCurrentScreenWindows = $1 }),
    BoolSpec(name: "collapsesToButton", key: "wharf.collapsesToButton", defaultValue: false,
             read: { $0.collapsesToButton }, write: { $0.collapsesToButton = $1 }),
    BoolSpec(name: "showsMediaProgressOnTiles", key: "wharf.showsMediaProgressOnTiles", defaultValue: true,
             read: { $0.showsMediaProgressOnTiles }, write: { $0.showsMediaProgressOnTiles = $1 }),
    BoolSpec(name: "windowsKeyboardMode", key: "wharf.windowsKeyboardMode", defaultValue: false,
             read: { $0.windowsKeyboardMode }, write: { $0.windowsKeyboardMode = $1 }),
    BoolSpec(name: "windowsKeyboardSnipShortcut", key: "wharf.windowsKeyboardSnipShortcut", defaultValue: true,
             read: { $0.windowsKeyboardSnipShortcut }, write: { $0.windowsKeyboardSnipShortcut = $1 }),
    BoolSpec(name: "showsAppBadges", key: "docky.showsAppBadges", defaultValue: true,
             read: { $0.showsAppBadges }, write: { $0.showsAppBadges = $1 }),
    BoolSpec(name: "opensAtLogin", key: "docky.opensAtLogin", defaultValue: true,
             read: { $0.opensAtLogin }, write: nil),
    BoolSpec(name: "hidesSystemDock", key: "docky.hidesSystemDock", defaultValue: true,
             read: { $0.hidesSystemDock }, write: nil),
    BoolSpec(name: "enablesWidgetHoverPreview", key: "docky.enablesWidgetHoverPreview", defaultValue: true,
             read: { $0.enablesWidgetHoverPreview }, write: { $0.enablesWidgetHoverPreview = $1 }),
    BoolSpec(name: "showsActivePinnedSeparator", key: "docky.showsActivePinnedSeparator", defaultValue: true,
             read: { $0.showsActivePinnedSeparator }, write: { $0.showsActivePinnedSeparator = $1 }),
    BoolSpec(name: "showsRunningApps", key: "docky.showsRunningApps", defaultValue: true,
             read: { $0.showsRunningApps }, write: { $0.showsRunningApps = $1 }),
    BoolSpec(name: "showsMinimizedWindows", key: "docky.showsMinimizedWindows", defaultValue: true,
             read: { $0.showsMinimizedWindows }, write: { $0.showsMinimizedWindows = $1 }),
    BoolSpec(name: "hidesDuringFullscreen", key: "docky.hidesDuringFullscreen", defaultValue: true,
             read: { $0.hidesDuringFullscreen }, write: { $0.hidesDuringFullscreen = $1 }),
    BoolSpec(name: "enablesShelveMode", key: "docky.enablesShelveMode", defaultValue: false,
             read: { $0.enablesShelveMode }, write: { $0.enablesShelveMode = $1 }),
    BoolSpec(name: "shelveHidesFinder", key: "docky.shelveHidesFinder", defaultValue: true,
             read: { $0.shelveHidesFinder }, write: { $0.shelveHidesFinder = $1 }),
    BoolSpec(name: "shelveHidesTrash", key: "docky.shelveHidesTrash", defaultValue: true,
             read: { $0.shelveHidesTrash }, write: { $0.shelveHidesTrash = $1 }),
    BoolSpec(name: "hidesRecentApps", key: "docky.hidesRecentApps", defaultValue: false,
             read: { $0.hidesRecentApps }, write: { $0.hidesRecentApps = $1 }),
    BoolSpec(name: "hidesProfileStrip", key: "docky.hidesProfileStrip", defaultValue: false,
             read: { $0.hidesProfileStrip }, write: { $0.hidesProfileStrip = $1 }),
    BoolSpec(name: "mirrorsLeftDividerOnRight", key: "docky.mirrorsLeftDividerOnRight", defaultValue: false,
             read: { $0.mirrorsLeftDividerOnRight }, write: { $0.mirrorsLeftDividerOnRight = $1 }),
    BoolSpec(name: "showsGroupedOpenedAppsInDock", key: "docky.showsGroupedOpenedAppsInDock", defaultValue: true,
             read: { $0.showsGroupedOpenedAppsInDock }, write: { $0.showsGroupedOpenedAppsInDock = $1 }),
    BoolSpec(name: "showsGroupedOpenedAppsBackdrop", key: "docky.showsGroupedOpenedAppsBackdrop", defaultValue: true,
             read: { $0.showsGroupedOpenedAppsBackdrop }, write: { $0.showsGroupedOpenedAppsBackdrop = $1 }),
    BoolSpec(name: "enablesLaunchpadOverlay", key: "docky.enablesLaunchpadOverlay", defaultValue: true,
             read: { $0.enablesLaunchpadOverlay }, write: { $0.enablesLaunchpadOverlay = $1 }),
    BoolSpec(name: "enablesStartMenuOverlay", key: "docky.enablesStartMenuOverlay", defaultValue: true,
             read: { $0.enablesStartMenuOverlay }, write: { $0.enablesStartMenuOverlay = $1 }),
    BoolSpec(name: "opensStartMenuFromFinderTile", key: "docky.opensStartMenuFromFinderTile", defaultValue: false,
             read: { $0.opensStartMenuFromFinderTile }, write: { $0.opensStartMenuFromFinderTile = $1 }),
    BoolSpec(name: "launchpadBackgroundBlursImage", key: "docky.launchpadBackgroundBlursImage", defaultValue: true,
             read: { $0.launchpadBackgroundBlursImage }, write: { $0.launchpadBackgroundBlursImage = $1 }),
    BoolSpec(name: "enablesWindowSwitcher", key: "docky.enablesWindowSwitcher", defaultValue: true,
             read: { $0.enablesWindowSwitcher }, write: { $0.enablesWindowSwitcher = $1 }),
    BoolSpec(name: "includesMinimizedWindows", key: "docky.includesMinimizedWindows", defaultValue: true,
             read: { $0.includesMinimizedWindows }, write: { $0.includesMinimizedWindows = $1 }),
    BoolSpec(name: "showsWindowSwitcherFocusPreview", key: "docky.showsWindowSwitcherFocusPreview", defaultValue: true,
             read: { $0.showsWindowSwitcherFocusPreview }, write: { $0.showsWindowSwitcherFocusPreview = $1 }),
    BoolSpec(name: "hasSeenDockEditorHint", key: "docky.hasSeenDockEditorHint", defaultValue: false,
             read: { $0.hasSeenDockEditorHint }, write: { $0.hasSeenDockEditorHint = $1 }),
]

final class BoolPreferenceTests: DockyPreferencesTestCase {
    func testSpecTableHasUniqueKeys() {
        XCTAssertEqual(Set(boolSpecs.map(\.key)).count, boolSpecs.count)
        XCTAssertEqual(boolSpecs.count, 31)
    }

    func testMissingKeyYieldsDefault() {
        // `hidesSystemDock` is seeded by the base class; remove it so the default is exercised.
        // `opensAtLogin` stays seeded because its missing-key default asks the login-item service.
        defaults.removeObject(forKey: PrefKeys.hidesSystemDock)
        let prefs = makePrefs()
        for spec in boolSpecs where spec.name != "opensAtLogin" {
            XCTAssertEqual(spec.read(prefs), spec.defaultValue, spec.name)
        }
    }

    func testStoredValuesRoundTripThroughInit() {
        for spec in boolSpecs {
            for value in [true, false] {
                defaults.set(value, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), value, "\(spec.name)=\(value)")
            }
        }
    }

    func testWrongTypeFallsBackToDefault() {
        for spec in boolSpecs {
            for wrong in ["yes", "no", "maybe", "", Data([1]), [true], ["k": true]] as [Any] {
                defaults.set(wrong, forKey: spec.key)
                // A wrong-typed `opensAtLogin` falls back to the machine's real
                // login-item state, so the expected value depends on the host.
                let expected = spec.name == "opensAtLogin"
                    ? LaunchAtLoginService.shared.isEnabled
                    : spec.defaultValue
                XCTAssertEqual(spec.read(makePrefs()), expected, "\(spec.name) \(type(of: wrong))")
            }
        }
    }

    func testOneBadBoolDoesNotDisturbOthers() {
        defaults.set("garbage", forKey: PrefKeys.showsAppBadges)
        defaults.set(false, forKey: PrefKeys.showsRunningApps)
        let prefs = makePrefs()
        XCTAssertTrue(prefs.showsAppBadges)
        XCTAssertFalse(prefs.showsRunningApps)
    }

    func testSetterPersistsAndSurvivesReload() {
        for spec in boolSpecs {
            guard let write = spec.write else { continue }
            let prefs = makePrefs()
            write(prefs, !spec.defaultValue)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Bool, !spec.defaultValue, spec.name)
            XCTAssertEqual(spec.read(reload()), !spec.defaultValue, spec.name)
        }
    }

    func testSettingTheDefaultWritesNothing() {
        for spec in boolSpecs {
            guard let write = spec.write else { continue }
            let prefs = makePrefs()
            write(prefs, spec.defaultValue)
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
        }
    }

    func testToggleBackOverwritesTheStoredValue() {
        for spec in boolSpecs {
            guard let write = spec.write else { continue }
            let prefs = makePrefs()
            write(prefs, !spec.defaultValue)
            write(prefs, spec.defaultValue)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Bool, spec.defaultValue, spec.name)
            XCTAssertEqual(spec.read(reload()), spec.defaultValue, spec.name)
        }
    }

    func testOpensAtLoginStoredValueWinsOverLoginItemState() {
        for value in [true, false] {
            defaults.set(value, forKey: PrefKeys.opensAtLogin)
            XCTAssertEqual(makePrefs().opensAtLogin, value)
        }
    }

    func testHidesSystemDockStoredValueIsReadWithoutTouchingTheDock() {
        for value in [true, false] {
            defaults.set(value, forKey: PrefKeys.hidesSystemDock)
            XCTAssertEqual(makePrefs().hidesSystemDock, value)
        }
    }
}
