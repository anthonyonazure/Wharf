import AppKit
import XCTest
@testable import Wharf

/// `DockTileProjection.project(_:screen:mode:filtersToScreen:grouping:windows:)`
/// is the pure core of the per-dock tile list. These tests cover everything
/// reachable without live windows: `AppWindow` wraps an `AXUIElement` and has
/// no public initializer, so per-window card expansion and
/// `isWindow(_:on:)` are not exercised here.
@MainActor
final class DockTileProjectionTests: XCTestCase {
    private func app(_ id: String, prefix: String = "pinned") -> Tile {
        Tile(id: "\(prefix):\(id)", content: .app(AppTile(bundleIdentifier: id, displayName: id)))
    }

    private var mixed: [Tile] {
        [
            app("com.apple.finder"),
            app("com.apple.Safari"),
            app("com.example.running", prefix: "running"),
            Tile(id: "divider:running", content: .divider),
            Tile(id: "spacer", content: .spacer),
            Tile(id: "flex", content: .flexibleSpacer),
            Tile(id: "widget", content: .widget(WidgetTile(
                identifier: "o:clock", title: "Clock", kind: .clock, ownerBundleIdentifier: "o", span: .one
            ))),
            Tile(id: "folder", content: .appFolder(AppFolderTile(
                identifier: "f", displayName: "F",
                apps: [AppTile(bundleIdentifier: "x", displayName: "x"), AppTile(bundleIdentifier: "y", displayName: "y")]
            ))),
            Tile(id: "trailing:trash", content: .trash),
        ]
    }

    private func project(
        _ tiles: [Tile],
        mode: DockContentMode = .dock,
        filters: Bool = false,
        grouping: DockWindowGrouping = .automatic,
        screen: NSScreen? = nil
    ) -> [Tile] {
        DockTileProjection.project(tiles, screen: screen, mode: mode, filtersToScreen: filters, grouping: grouping, windows: [])
    }

    func testDefaultConfigurationReturnsTilesUnchanged() {
        XCTAssertEqual(project(mixed), mixed)
    }

    func testEmptyListStaysEmptyInEveryConfiguration() {
        for mode in DockContentMode.allCases {
            for filters in [false, true] {
                for grouping in DockWindowGrouping.allCases {
                    XCTAssertEqual(project([], mode: mode, filters: filters, grouping: grouping), [])
                }
            }
        }
    }

    func testTaskbarModeWithoutWindowsLeavesEverythingAlone() {
        XCTAssertEqual(project(mixed, mode: .taskbar), mixed)
    }

    func testGroupingIsIrrelevantWithoutWindows() {
        let results = DockWindowGrouping.allCases.map { project(mixed, mode: .taskbar, grouping: $0) }
        for result in results {
            XCTAssertEqual(result, mixed)
        }
    }

    func testScreenFilterDropsRunningAppsWithNothingOnThisScreen() {
        let result = project(mixed, filters: true)
        XCTAssertFalse(result.contains { $0.id == "running:com.example.running" })
    }

    func testScreenFilterKeepsPinnedAppsLikeLaunchers() {
        let result = project(mixed, filters: true).map(\.id)
        XCTAssertTrue(result.contains("pinned:com.apple.finder"))
        XCTAssertTrue(result.contains("pinned:com.apple.Safari"))
    }

    func testScreenFilterKeepsNonAppTiles() {
        let result = project(mixed, filters: true).map(\.id)
        for id in ["divider:running", "spacer", "flex", "widget", "folder", "trailing:trash"] {
            XCTAssertTrue(result.contains(id), id)
        }
    }

    func testScreenFilterPreservesOrder() {
        let expected = mixed.filter { $0.id != "running:com.example.running" }
        XCTAssertEqual(project(mixed, filters: true), expected)
    }

    func testScreenFilterAppliesInTaskbarModeToo() {
        XCTAssertEqual(
            project(mixed, mode: .taskbar, filters: true),
            mixed.filter { $0.id != "running:com.example.running" }
        )
    }

    func testPinnedIsDecidedByIDPrefixOnly() {
        let tiles = [
            app("a", prefix: "pinned"),
            app("b", prefix: "pinnedish"),
            Tile(id: "pinned", content: .app(AppTile(bundleIdentifier: "c", displayName: "c"))),
            app("d", prefix: "trailing"),
            app("e", prefix: "running"),
        ]
        XCTAssertEqual(project(tiles, filters: true).map(\.id), ["pinned:a"])
    }

    func testFilteringIsIdempotent() {
        let once = project(mixed, filters: true)
        XCTAssertEqual(project(once, filters: true), once)
    }

    func testNilAndRealScreenAgreeWhenThereAreNoWindows() {
        XCTAssertEqual(project(mixed, filters: true, screen: nil), project(mixed, filters: true, screen: NSScreen.main))
    }

    func testLargeListsProjectQuickly() {
        let tiles = (0..<10_000).map { app("id\($0)", prefix: $0.isMultiple(of: 2) ? "pinned" : "running") }
        let result = project(tiles, mode: .taskbar, filters: true)
        XCTAssertEqual(result.count, 5_000)
    }

    func testDuplicateTileIDsPassThroughWithoutTrapping() {
        let tiles = [app("a"), app("a"), app("a", prefix: "running"), app("a", prefix: "running")]
        XCTAssertEqual(project(tiles, filters: true).count, 2)
        XCTAssertEqual(project(tiles).count, 4)
    }

    func testEnumsExposeStableRawValues() {
        // Persisted in UserDefaults; renaming would silently reset the user's choice.
        XCTAssertEqual(DockContentMode.allCases.map(\.rawValue), ["dock", "taskbar"])
        XCTAssertEqual(DockWindowGrouping.allCases.map(\.rawValue), ["always", "never", "automatic"])
    }
}
