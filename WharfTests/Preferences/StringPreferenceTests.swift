import XCTest
@testable import Wharf

private struct PathSpec {
    let name: String
    let key: String
    let read: (DockyPreferences) -> String?
    let write: (DockyPreferences, String?) -> Void
}

private let pathSpecs: [PathSpec] = [
    PathSpec(name: "tileHoverBackgroundImagePath", key: "docky.tileHoverBackgroundImagePath",
             read: { $0.tileHoverBackgroundImagePath }, write: { $0.tileHoverBackgroundImagePath = $1 }),
    PathSpec(name: "tileActiveBackgroundImagePath", key: "docky.tileActiveBackgroundImagePath",
             read: { $0.tileActiveBackgroundImagePath }, write: { $0.tileActiveBackgroundImagePath = $1 }),
    PathSpec(name: "windowBackgroundImagePath", key: "docky.windowBackgroundImagePath",
             read: { $0.windowBackgroundImagePath }, write: { $0.windowBackgroundImagePath = $1 }),
    PathSpec(name: "activeIndicatorImagePath", key: "docky.activeIndicatorImagePath",
             read: { $0.activeIndicatorImagePath }, write: { $0.activeIndicatorImagePath = $1 }),
    PathSpec(name: "dividerImagePath", key: "docky.dividerImagePath",
             read: { $0.dividerImagePath }, write: { $0.dividerImagePath = $1 }),
    PathSpec(name: "leftDividerImagePath", key: "docky.leftDividerImagePath",
             read: { $0.leftDividerImagePath }, write: { $0.leftDividerImagePath = $1 }),
    PathSpec(name: "rightDividerImagePath", key: "docky.rightDividerImagePath",
             read: { $0.rightDividerImagePath }, write: { $0.rightDividerImagePath = $1 }),
    PathSpec(name: "launchpadIconPath", key: "docky.launchpadIconPath",
             read: { $0.launchpadIconPath }, write: { $0.launchpadIconPath = $1 }),
    PathSpec(name: "startMenuIconPath", key: "docky.startMenuIconPath",
             read: { $0.startMenuIconPath }, write: { $0.startMenuIconPath = $1 }),
    PathSpec(name: "launchpadBackgroundImagePath", key: "docky.launchpadBackgroundImagePath",
             read: { $0.launchpadBackgroundImagePath }, write: { $0.launchpadBackgroundImagePath = $1 }),
]

/// Image-path preferences and the string-array preferences.
final class StringPreferenceTests: DockyPreferencesTestCase {

    // MARK: Optional image paths

    func testPathsDefaultToNil() {
        let prefs = makePrefs()
        for spec in pathSpecs {
            XCTAssertNil(spec.read(prefs), spec.name)
        }
    }

    func testStoredPathsRoundTripVerbatim() {
        let paths = [
            "/Users/someone/Pictures/icon.png",
            "relative/path.png",
            "~/Pictures/tilde.png",
            "/path with spaces/and unicode \u{1F642}.png",
            "../../../etc/passwd",
            "file:///tmp/x.png",
            String(repeating: "a", count: 200_000),
        ]
        for spec in pathSpecs {
            for path in paths {
                defaults.set(path, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), path, "\(spec.name) \(path.prefix(24))")
            }
        }
    }

    func testPathsWithEmbeddedNulDoNotTrap() {
        for spec in pathSpecs {
            defaults.set("/tmp/a\0b.png", forKey: spec.key)
            _ = spec.read(makePrefs())
        }
    }

    func testWrongTypeForPathFallsBackToNil() {
        for spec in pathSpecs {
            for wrong in [Data([1, 2]), ["a"], ["k": "v"], Date(timeIntervalSince1970: 0)] as [Any] {
                defaults.set(wrong, forKey: spec.key)
                XCTAssertNil(spec.read(makePrefs()), "\(spec.name) \(type(of: wrong))")
            }
        }
    }

    func testPathSetterPersistsAndSurvivesReload() {
        for spec in pathSpecs {
            let prefs = makePrefs()
            spec.write(prefs, "/tmp/\(spec.name).png")
            XCTAssertEqual(defaults.string(forKey: spec.key), "/tmp/\(spec.name).png", spec.name)
            XCTAssertEqual(spec.read(reload()), "/tmp/\(spec.name).png", spec.name)
        }
    }

    func testClearingPathWithNilRemovesTheKey() {
        for spec in pathSpecs {
            let prefs = makePrefs()
            spec.write(prefs, "/tmp/x.png")
            spec.write(prefs, nil)
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
            XCTAssertNil(spec.read(reload()), spec.name)
        }
    }

    func testAssigningEmptyPathRemovesTheKey() {
        for spec in pathSpecs {
            let prefs = makePrefs()
            spec.write(prefs, "/tmp/x.png")
            spec.write(prefs, "")
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
            XCTAssertNil(spec.read(reload()), spec.name)
        }
    }

    func testEmptyStoredPathLoadsAsEmptyStringNotNil() {
        // Documents current behavior: only the setter normalizes "" to nil. Every
        // consumer already guards with `!path.isEmpty`, so "" is harmless.
        for spec in pathSpecs {
            defaults.set("", forKey: spec.key)
            XCTAssertEqual(spec.read(makePrefs()), "", spec.name)
        }
    }

    // MARK: Optional padding fractions

    func testIconPaddingFractionsDefaultToNilAndRoundTrip() {
        let empty = makePrefs()
        XCTAssertNil(empty.launchpadIconPaddingFraction)
        XCTAssertNil(empty.startMenuIconPaddingFraction)
        defaults.set(0.2, forKey: PrefKeys.launchpadIconPaddingFraction)
        defaults.set(0.3, forKey: PrefKeys.startMenuIconPaddingFraction)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.launchpadIconPaddingFraction, 0.2)
        XCTAssertEqual(prefs.startMenuIconPaddingFraction, 0.3)
    }

    func testIconPaddingFractionsAreNotClampedAtLoad() {
        // Callers document 0...0.5 but nothing enforces it; confirm hostile values
        // load without trapping so the render layer is the only place to guard.
        for hostile in [-5.0, 0.51, 1e9, Double.infinity, -Double.infinity, Double.nan] {
            defaults.set(hostile, forKey: PrefKeys.launchpadIconPaddingFraction)
            defaults.set(hostile, forKey: PrefKeys.startMenuIconPaddingFraction)
            let prefs = makePrefs()
            XCTAssertNotNil(prefs.launchpadIconPaddingFraction)
            XCTAssertNotNil(prefs.startMenuIconPaddingFraction)
        }
    }

    func testIconPaddingFractionWrongTypeIsNil() {
        defaults.set("0.2", forKey: PrefKeys.launchpadIconPaddingFraction)
        defaults.set(Data([1]), forKey: PrefKeys.startMenuIconPaddingFraction)
        let prefs = makePrefs()
        XCTAssertNil(prefs.launchpadIconPaddingFraction)
        XCTAssertNil(prefs.startMenuIconPaddingFraction)
    }

    func testIconPaddingFractionSetterRemovesKeyOnNil() {
        let prefs = makePrefs()
        prefs.launchpadIconPaddingFraction = 0.1
        XCTAssertEqual(defaults.object(forKey: PrefKeys.launchpadIconPaddingFraction) as? Double, 0.1)
        prefs.launchpadIconPaddingFraction = nil
        XCTAssertNil(defaults.object(forKey: PrefKeys.launchpadIconPaddingFraction))
        prefs.startMenuIconPaddingFraction = 0.4
        XCTAssertEqual(reload().startMenuIconPaddingFraction, 0.4)
    }

    // MARK: Bundle identifier lists

    func testDefaultStayBehindListNamesRemoteDesktopClients() {
        let ids = makePrefs().dockStaysBehindBundleIDs
        XCTAssertTrue(ids.contains("com.microsoft.rdc.macos"))
        XCTAssertTrue(ids.contains("com.parallels.desktop.console"))
        XCTAssertEqual(ids.count, 10)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultKeyboardExclusionsAreTerminals() {
        let ids = makePrefs().windowsKeyboardExcludedBundleIDs
        XCTAssertTrue(ids.contains("com.apple.Terminal"))
        XCTAssertTrue(ids.contains("com.googlecode.iterm2"))
        XCTAssertEqual(ids.count, 8)
    }

    func testBundleListsRoundTripVerbatimWithoutNormalizing() {
        let list = ["z.app", "a.app", "a.app", "", "  spaced  "]
        defaults.set(list, forKey: PrefKeys.dockStaysBehindBundleIDs)
        defaults.set(list, forKey: PrefKeys.windowsKeyboardExcludedBundleIDs)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.dockStaysBehindBundleIDs, list)
        XCTAssertEqual(prefs.windowsKeyboardExcludedBundleIDs, list)
    }

    func testEmptyStoredListIsKeptNotReplacedByDefault() {
        defaults.set([String](), forKey: PrefKeys.dockStaysBehindBundleIDs)
        defaults.set([String](), forKey: PrefKeys.windowsKeyboardExcludedBundleIDs)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.dockStaysBehindBundleIDs, [])
        XCTAssertEqual(prefs.windowsKeyboardExcludedBundleIDs, [])
    }

    func testBundleListWrongTypeFallsBackToDefault() {
        let defaultPrefs = makePrefs()
        let expectedStay = defaultPrefs.dockStaysBehindBundleIDs
        let expectedExcluded = defaultPrefs.windowsKeyboardExcludedBundleIDs
        for wrong in ["com.x.y", [1, 2, 3], [["nested"]], ["k": "v"], Data([1])] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.dockStaysBehindBundleIDs)
            defaults.set(wrong, forKey: PrefKeys.windowsKeyboardExcludedBundleIDs)
            let prefs = makePrefs()
            XCTAssertEqual(prefs.dockStaysBehindBundleIDs, expectedStay, "\(type(of: wrong))")
            XCTAssertEqual(prefs.windowsKeyboardExcludedBundleIDs, expectedExcluded, "\(type(of: wrong))")
        }
    }

    func testHugeBundleListLoads() {
        let list = (0..<20_000).map { "com.example.app\($0)" }
        defaults.set(list, forKey: PrefKeys.dockStaysBehindBundleIDs)
        XCTAssertEqual(makePrefs().dockStaysBehindBundleIDs.count, 20_000)
    }

    func testBundleListSettersPersist() {
        let prefs = makePrefs()
        prefs.dockStaysBehindBundleIDs = ["a.b"]
        prefs.windowsKeyboardExcludedBundleIDs = ["c.d"]
        let reloaded = reload()
        XCTAssertEqual(reloaded.dockStaysBehindBundleIDs, ["a.b"])
        XCTAssertEqual(reloaded.windowsKeyboardExcludedBundleIDs, ["c.d"])
    }

    // MARK: Photo frame bookmarks

    func testPhotoFrameBookmarksDefaultEmptyAndRoundTrip() {
        XCTAssertEqual(makePrefs().photoFrameBookmarks, [])
        let blobs = [Data([1, 2, 3]), Data(), Data(repeating: 0xFF, count: 4096)]
        defaults.set(blobs, forKey: PrefKeys.photoFrameBookmarks)
        XCTAssertEqual(makePrefs().photoFrameBookmarks, blobs)
    }

    func testPhotoFrameBookmarksWrongTypeIsEmpty() {
        for wrong in ["bookmark", ["a", "b"], [1, 2], Data([1])] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.photoFrameBookmarks)
            XCTAssertEqual(makePrefs().photoFrameBookmarks, [], "\(type(of: wrong))")
        }
    }

    func testPhotoFrameBookmarksEmptyAssignmentRemovesKey() {
        let prefs = makePrefs()
        prefs.photoFrameBookmarks = [Data([9])]
        XCTAssertNotNil(defaults.object(forKey: PrefKeys.photoFrameBookmarks))
        prefs.photoFrameBookmarks = []
        XCTAssertNil(defaults.object(forKey: PrefKeys.photoFrameBookmarks))
    }

    // MARK: Widget hover spans

    func testWidgetHoverSpansDefaultToEverySpan() {
        XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, Set(TileSpan.allCases))
    }

    func testWidgetHoverSpansDropUnknownRawValues() {
        defaults.set([1, 3, 0, 5, -1, Int.max], forKey: PrefKeys.widgetHoverPreviewSpans)
        XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, [.one, .three])
    }

    func testWidgetHoverSpansAllUnknownBecomesEmptySet() {
        defaults.set([0, 5, 99], forKey: PrefKeys.widgetHoverPreviewSpans)
        XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, [])
    }

    func testWidgetHoverSpansEmptyArrayIsEmptySetNotDefault() {
        defaults.set([Int](), forKey: PrefKeys.widgetHoverPreviewSpans)
        XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, [])
    }

    func testWidgetHoverSpansDuplicatesCollapse() {
        defaults.set([2, 2, 2, 2], forKey: PrefKeys.widgetHoverPreviewSpans)
        XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, [.two])
    }

    func testWidgetHoverSpansWrongTypeFallsBackToDefault() {
        for wrong in [["one", "two"], "1,2", Data([1])] as [Any] {
            defaults.set(wrong, forKey: PrefKeys.widgetHoverPreviewSpans)
            XCTAssertEqual(makePrefs().widgetHoverPreviewSpans, Set(TileSpan.allCases), "\(type(of: wrong))")
        }
    }

    func testWidgetHoverSpansSetterPersistsRawValues() {
        let prefs = makePrefs()
        prefs.widgetHoverPreviewSpans = [.two, .four]
        let stored = (defaults.array(forKey: PrefKeys.widgetHoverPreviewSpans) as? [Int]) ?? []
        XCTAssertEqual(Set(stored), [2, 4])
        XCTAssertEqual(reload().widgetHoverPreviewSpans, [.two, .four])
    }
}
