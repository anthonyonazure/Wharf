import XCTest
@testable import Wharf

/// Integer-backed preferences: the dock row count, the Launchpad grid, and the
/// three window-switcher key codes.
final class IntegerPreferenceTests: DockyPreferencesTestCase {

    // MARK: dockRowCount (setter clamps 1...5; the loader does not)

    func testDockRowCountDefaultsToOne() {
        XCTAssertEqual(makePrefs().dockRowCount, 1)
    }

    func testDockRowCountInRangeRoundTrips() {
        for rows in 1...5 {
            defaults.set(rows, forKey: PrefKeys.dockRowCount)
            XCTAssertEqual(makePrefs().dockRowCount, rows)
        }
    }

    func testDockRowCountSetterClampsToOneThroughFive() {
        let prefs = makePrefs()
        prefs.dockRowCount = 99
        XCTAssertEqual(prefs.dockRowCount, 5)
        prefs.dockRowCount = -4
        XCTAssertEqual(prefs.dockRowCount, 1)
        prefs.dockRowCount = Int.max
        XCTAssertEqual(prefs.dockRowCount, 5)
        prefs.dockRowCount = Int.min
        XCTAssertEqual(prefs.dockRowCount, 1)
    }

    func testDockRowCountSetterPersistsTheClampedValue() {
        let prefs = makePrefs()
        prefs.dockRowCount = 42
        XCTAssertEqual(defaults.object(forKey: PrefKeys.dockRowCount) as? Int, 5)
        XCTAssertEqual(reload().dockRowCount, 5)
    }

    func testDockRowCountSetterRoundTrip() {
        let prefs = makePrefs()
        prefs.dockRowCount = 3
        XCTAssertEqual(defaults.object(forKey: PrefKeys.dockRowCount) as? Int, 3)
        XCTAssertEqual(reload().dockRowCount, 3)
    }

    /// The setter and the settings stepper both bound this to 1...5, so a value
    /// outside that range loaded from storage is out of contract. Layout code
    /// re-clamps at each use site, which hides the gap rather than closing it.
    func testDockRowCountStoredOutOfRangeIsClampedAtLoad() {
        for hostile in [0, -1, -300, 6, 99, Int.max, Int.min] {
            defaults.set(hostile, forKey: PrefKeys.dockRowCount)
            let loaded = makePrefs().dockRowCount
            XCTAssertTrue((1...5).contains(loaded), "loaded \(loaded)")
        }
    }

    func testDockRowCountWrongTypeFallsBackToDefault() {
        for wrong in ["3", "many", Data([3]), [3], ["rows": 3]] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.dockRowCount)
            XCTAssertEqual(makePrefs().dockRowCount, 1, "\(type(of: wrong))")
        }
    }

    func testDockRowCountFractionalDoubleFallsBackToDefault() {
        defaults.set(4.5, forKey: PrefKeys.dockRowCount)
        XCTAssertEqual(makePrefs().dockRowCount, 1)
    }

    func testDockRowCountHugeDoubleDoesNotTrap() {
        for hostile in [1e30, -1e30, Double.infinity, -Double.infinity, Double.nan] {
            defaults.set(hostile, forKey: PrefKeys.dockRowCount)
            _ = makePrefs().dockRowCount
        }
    }

    // MARK: Launchpad grid counts (floor of 1, no ceiling)

    private struct GridSpec {
        let name: String
        let key: String
        let defaultValue: Int
        let read: (DockyPreferences) -> Int
        let write: (DockyPreferences, Int) -> Void
    }

    private var gridSpecs: [GridSpec] {
        [
            GridSpec(name: "columns", key: PrefKeys.launchpadGridColumnCount, defaultValue: 7,
                     read: { $0.launchpadGridColumnCount }, write: { $0.launchpadGridColumnCount = $1 }),
            GridSpec(name: "rows", key: PrefKeys.launchpadGridRowCount, defaultValue: 5,
                     read: { $0.launchpadGridRowCount }, write: { $0.launchpadGridRowCount = $1 }),
        ]
    }

    func testLaunchpadGridDefaults() {
        let prefs = makePrefs()
        for spec in gridSpecs {
            XCTAssertEqual(spec.read(prefs), spec.defaultValue, spec.name)
        }
    }

    func testLaunchpadGridInRangeValuesRoundTrip() {
        for spec in gridSpecs {
            for value in [1, 2, 7, 12, 100] {
                defaults.set(value, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), value, "\(spec.name)=\(value)")
            }
        }
    }

    func testLaunchpadGridBelowOneClampsToOne() {
        for spec in gridSpecs {
            for hostile in [0, -1, -9999, Int.min] {
                defaults.set(hostile, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), 1, "\(spec.name)=\(hostile)")
            }
        }
    }

    func testLaunchpadGridHugeValuesDoNotTrap() {
        for spec in gridSpecs {
            defaults.set(Int.max, forKey: spec.key)
            XCTAssertEqual(spec.read(makePrefs()), Int.max, spec.name)
        }
    }

    func testLaunchpadGridWrongTypeFallsBackToDefault() {
        for spec in gridSpecs {
            for wrong in ["seven", "7", Data([7]), [7]] as [Any] {
                defaults.set(wrong, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultValue, "\(spec.name) \(type(of: wrong))")
            }
        }
    }

    func testLaunchpadGridSettersClampAndPersist() {
        for spec in gridSpecs {
            let prefs = makePrefs()
            spec.write(prefs, -8)
            XCTAssertEqual(spec.read(prefs), 1, spec.name)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Int, 1, spec.name)
            spec.write(prefs, 9)
            XCTAssertEqual(spec.read(reload()), 9, spec.name)
        }
    }

    // MARK: Window switcher key codes (UInt16, so out-of-range ints are rejected)

    private struct KeyCodeSpec {
        let name: String
        let key: String
        let defaultValue: UInt16
        let read: (DockyPreferences) -> UInt16
        let write: (DockyPreferences, UInt16) -> Void
    }

    private var keyCodeSpecs: [KeyCodeSpec] {
        [
            KeyCodeSpec(name: "minimize", key: PrefKeys.switcherMinimizeKeyCode, defaultValue: 46,
                        read: { $0.switcherMinimizeKeyCode }, write: { $0.switcherMinimizeKeyCode = $1 }),
            KeyCodeSpec(name: "close", key: PrefKeys.switcherCloseKeyCode, defaultValue: 13,
                        read: { $0.switcherCloseKeyCode }, write: { $0.switcherCloseKeyCode = $1 }),
            KeyCodeSpec(name: "zoom", key: PrefKeys.switcherZoomKeyCode, defaultValue: 6,
                        read: { $0.switcherZoomKeyCode }, write: { $0.switcherZoomKeyCode = $1 }),
        ]
    }

    func testSwitcherKeyCodeDefaults() {
        let prefs = makePrefs()
        for spec in keyCodeSpecs {
            XCTAssertEqual(spec.read(prefs), spec.defaultValue, spec.name)
        }
    }

    func testSwitcherKeyCodeAcceptsEveryUInt16Boundary() {
        for spec in keyCodeSpecs {
            for value in [0, 1, 46, 255, 256, 32767, 32768, 65534, 65535] {
                defaults.set(value, forKey: spec.key)
                XCTAssertEqual(Int(spec.read(makePrefs())), value, "\(spec.name)=\(value)")
            }
        }
    }

    /// Regression for the September audit: `UInt16(x)` trapped on these.
    func testSwitcherKeyCodeOutOfRangeFallsBackToDefaultInsteadOfTrapping() {
        for spec in keyCodeSpecs {
            for hostile in [-1, -65535, 65536, 65537, 70000, 1_000_000, Int(Int32.max), Int.max, Int.min] {
                defaults.set(hostile, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultValue, "\(spec.name)=\(hostile)")
            }
        }
    }

    func testSwitcherKeyCodeWrongTypeFallsBackToDefault() {
        for spec in keyCodeSpecs {
            for wrong in ["46", "return", Data([46]), [46], ["k": 46]] as [Any] {
                defaults.set(wrong, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultValue, "\(spec.name) \(type(of: wrong))")
            }
        }
    }

    func testSwitcherKeyCodeHugeDoubleFallsBackToDefault() {
        for spec in keyCodeSpecs {
            for hostile in [1e30, -1e30, Double.infinity, Double.nan, 70000.0] {
                defaults.set(hostile, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultValue, "\(spec.name)=\(hostile)")
            }
        }
    }

    func testSwitcherKeyCodeSettersPersistAsInts() {
        for spec in keyCodeSpecs {
            let prefs = makePrefs()
            spec.write(prefs, 99)
            XCTAssertEqual(defaults.object(forKey: spec.key) as? Int, 99, spec.name)
            XCTAssertEqual(spec.read(reload()), 99, spec.name)
        }
    }

    func testSwitcherKeyCodeSetterAtUInt16Max() {
        for spec in keyCodeSpecs {
            let prefs = makePrefs()
            spec.write(prefs, UInt16.max)
            XCTAssertEqual(spec.read(reload()), UInt16.max, spec.name)
        }
    }

    func testSwitcherKeyCodeSetterWritesNothingForTheDefault() {
        for spec in keyCodeSpecs {
            let prefs = makePrefs()
            spec.write(prefs, spec.defaultValue)
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
        }
    }

    func testOneBadKeyCodeDoesNotDisturbItsNeighbours() {
        defaults.set(70000, forKey: PrefKeys.switcherMinimizeKeyCode)
        defaults.set(12, forKey: PrefKeys.switcherCloseKeyCode)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.switcherMinimizeKeyCode, 46)
        XCTAssertEqual(prefs.switcherCloseKeyCode, 12)
        XCTAssertEqual(prefs.switcherZoomKeyCode, 6)
    }
}
