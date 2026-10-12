import Combine
import XCTest
@testable import Wharf

/// WindowRegistry bookkeeping: ordering, replacement, removal, focus bumps,
/// minimized/visible filtering and pid reuse. The registry is built with
/// `observesSystem: false`, so there are no AX observers and no workspace
/// notifications, and windows are fed in directly.
@MainActor
final class WindowRegistryTests: LayoutTestCase {
    private var registry: WindowRegistry!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        registry = WindowRegistry(observesSystem: false)
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        registry = nil
        super.tearDown()
    }

    private func window(
        _ title: String,
        pid: pid_t = 100,
        bundle: String? = nil,
        minimized: Bool = false,
        frame: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600),
        cgWindowID: CGWindowID? = nil
    ) -> AppWindow {
        FakeWindows.make(
            bundle: bundle ?? "com.app.\(pid)",
            title: title,
            frame: frame,
            minimized: minimized,
            pid: pid,
            cgWindowID: cgWindowID
        )
    }

    private func titles() -> [String] { registry.windows.map(\.windowTitle) }

    private func publishedCount() -> () -> Int {
        var count = 0
        registry.$windows.dropFirst().sink { _ in count += 1 }.store(in: &cancellables)
        return { count }
    }

    // MARK: - Identity

    func testAFreshRegistryIsEmpty() {
        XCTAssertTrue(registry.windows.isEmpty)
        XCTAssertTrue(registry.minimized.isEmpty)
        XCTAssertTrue(registry.visible.isEmpty)
    }

    func testFakeWindowsHaveDistinctIdentifiers() {
        let ids = Set((0..<200).map { _ in FakeWindows.make().windowIdentifier })
        XCTAssertEqual(ids.count, 200)
    }

    func testWindowIdentifierHasTheStablePrefix() {
        XCTAssertTrue(FakeWindows.make().windowIdentifier.hasPrefix("ax:"))
    }

    func testTheSameElementGivesTheSameIdentityEvenWithOtherFields() {
        let element = FakeWindows.element()
        let one = FakeWindows.make(title: "One", element: element)
        let two = FakeWindows.make(title: "Two", element: element)
        XCTAssertEqual(one.id, two.id)
        XCTAssertEqual(one.windowIdentifier, two.windowIdentifier)
        XCTAssertNotEqual(one, two, "equality also compares the snapshot fields")
        XCTAssertEqual(one.hashValue, two.hashValue, "hashing is by identity alone")
    }

    func testEqualityComparesEverySnapshotField() {
        let element = FakeWindows.element()
        let base = FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), pid: 7, cgWindowID: 9, windowNumber: 5, element: element)
        XCTAssertEqual(base, FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), pid: 7, cgWindowID: 9, windowNumber: 5, element: element))
        XCTAssertNotEqual(base, FakeWindows.make(bundle: "c", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), pid: 7, cgWindowID: 9, windowNumber: 5, element: element))
        XCTAssertNotEqual(base, FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 5), pid: 7, cgWindowID: 9, windowNumber: 5, element: element))
        XCTAssertNotEqual(base, FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), pid: 8, cgWindowID: 9, windowNumber: 5, element: element))
        XCTAssertNotEqual(base, FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), pid: 7, cgWindowID: 10, windowNumber: 5, element: element))
        XCTAssertNotEqual(base, FakeWindows.make(bundle: "b", title: "t", frame: CGRect(x: 1, y: 2, width: 3, height: 4), minimized: true, pid: 7, cgWindowID: 9, windowNumber: 5, element: element))
    }

    func testScreenBoundsIsTheFrame() {
        let frame = CGRect(x: 5, y: 6, width: 70, height: 80)
        XCTAssertEqual(FakeWindows.make(frame: frame).screenBounds, frame)
        XCTAssertNil(FakeWindows.make(frame: nil).screenBounds)
    }

    // MARK: - applyOrdered

    func testNewWindowsAreAppendedInTheOrderGiven() {
        registry.applyOrdered([window("a"), window("b"), window("c")])
        XCTAssertEqual(titles(), ["a", "b", "c"])
    }

    func testExistingWindowsKeepTheirSlotAndTakeFreshFields() {
        let a = window("a")
        let b = window("b")
        registry.applyOrdered([a, b])
        let renamed = FakeWindows.make(bundle: a.bundleIdentifier, title: "a renamed", frame: a.frame, pid: a.processIdentifier, element: a.element)
        registry.applyOrdered([b, renamed])
        XCTAssertEqual(titles(), ["a renamed", "b"], "a keeps first place even though the snapshot lists b first")
    }

    func testWindowsMissingFromTheSnapshotAreDropped() {
        let a = window("a")
        let b = window("b")
        registry.applyOrdered([a, b])
        registry.applyOrdered([b])
        XCTAssertEqual(titles(), ["b"])
    }

    func testNewcomersGoAfterSurvivors() {
        let a = window("a")
        registry.applyOrdered([a])
        registry.applyOrdered([window("new"), a])
        XCTAssertEqual(titles(), ["a", "new"])
    }

    func testAnIdenticalSnapshotDoesNotPublish() {
        let a = window("a")
        let b = window("b")
        registry.applyOrdered([a, b])
        let count = publishedCount()
        registry.applyOrdered([a, b])
        registry.applyOrdered([b, a])
        XCTAssertEqual(count(), 0)
    }

    func testAChangedSnapshotPublishesOnce() {
        let a = window("a")
        registry.applyOrdered([a])
        let count = publishedCount()
        registry.applyOrdered([a, window("b")])
        XCTAssertEqual(count(), 1)
    }

    func testEmptySnapshotClearsTheRegistry() {
        registry.applyOrdered([window("a"), window("b")])
        registry.applyOrdered([])
        XCTAssertTrue(registry.windows.isEmpty)
    }

    func testAThousandWindowsKeepTheirOrder() {
        let all = (0..<1000).map { window("w\($0)", pid: pid_t(100 + $0 % 20)) }
        registry.applyOrdered(all)
        XCTAssertEqual(titles(), all.map(\.windowTitle))
        registry.applyOrdered(all.shuffled())
        XCTAssertEqual(titles(), all.map(\.windowTitle), "reshuffling the snapshot must not reorder the registry")
    }

    func testTheRegistryItselfDoesNotCapTheWindowCount() {
        registry.applyOrdered((0..<300).map { window("w\($0)") })
        XCTAssertEqual(registry.windows.count, 300)
    }

    // MARK: - Replace and remove by pid

    func testReplaceKeepsSurvivingWindowsInPlaceAndAppendsNewOnes() {
        let a1 = window("a1", pid: 1)
        let b1 = window("b1", pid: 2)
        let c1 = window("c1", pid: 3)
        registry.applyOrdered([a1, b1, c1])
        registry.replaceWindows(forPID: 2, with: [b1, window("b-new", pid: 2)])
        XCTAssertEqual(titles(), ["a1", "b1", "c1", "b-new"])
    }

    func testReplaceDropsWindowsTheAppNoLongerHas() {
        let a1 = window("a1", pid: 1)
        let b1 = window("b1", pid: 2)
        let b2 = window("b2", pid: 2)
        registry.applyOrdered([b1, a1, b2])
        registry.replaceWindows(forPID: 2, with: [b2])
        XCTAssertEqual(titles(), ["a1", "b2"])
    }

    func testReplaceWithNoWindowsRemovesTheApp() {
        registry.applyOrdered([window("a1", pid: 1), window("b1", pid: 2)])
        registry.replaceWindows(forPID: 1, with: [])
        XCTAssertEqual(titles(), ["b1"])
    }

    func testReplaceForAnUnknownPidAppends() {
        registry.applyOrdered([window("a1", pid: 1)])
        registry.replaceWindows(forPID: 9, with: [window("n", pid: 9)])
        XCTAssertEqual(titles(), ["a1", "n"])
    }

    func testReplaceKeepsTheFocusOrderOfSurvivingWindowsOfTheSameApp() {
        let one = window("one", pid: 1)
        let two = window("two", pid: 1)
        let other = window("other", pid: 2)
        registry.applyOrdered([one, other, two])
        registry.bumpWindowToTop(element: two.element, pid: 1)
        XCTAssertEqual(titles(), ["two", "one", "other"])
        registry.replaceWindows(forPID: 1, with: [one, two])
        XCTAssertEqual(titles(), ["two", "one", "other"], "AX enumeration order must not undo the focus order")
    }

    func testRemoveWindowsForPidRemovesOnlyThatApp() {
        registry.applyOrdered([window("a", pid: 1), window("b", pid: 2), window("c", pid: 1)])
        registry.removeWindows(for: 1)
        XCTAssertEqual(titles(), ["b"])
    }

    func testRemoveWindowsForUnknownPidIsSilent() {
        registry.applyOrdered([window("a", pid: 1)])
        let count = publishedCount()
        registry.removeWindows(for: 77)
        XCTAssertEqual(count(), 0)
        XCTAssertEqual(titles(), ["a"])
    }

    func testRemoveWindowByElement() {
        let a = window("a", pid: 1)
        let b = window("b", pid: 1)
        registry.applyOrdered([a, b])
        registry.removeWindow(matching: a.element, pid: 1)
        XCTAssertEqual(titles(), ["b"])
    }

    func testRemovingAnUnknownElementDropsTheAppsWindowsWhenTheAppIsGone() {
        // The fallback re-syncs the app; a pid that is not a running regular
        // app has no windows to keep.
        registry.applyOrdered([window("a", pid: 1_999_999), window("b", pid: 2)])
        registry.removeWindow(matching: FakeWindows.element(), pid: 1_999_999)
        XCTAssertEqual(titles(), ["b"])
    }

    // MARK: - Focus order

    func testBumpingMovesOnlyThatWindowToTheFront() {
        let a = window("a", pid: 1)
        let b = window("b", pid: 2)
        let c = window("c", pid: 3)
        registry.applyOrdered([a, b, c])
        registry.bumpWindowToTop(element: c.element, pid: 3)
        XCTAssertEqual(titles(), ["c", "a", "b"])
        registry.bumpWindowToTop(element: b.element, pid: 2)
        XCTAssertEqual(titles(), ["b", "c", "a"])
    }

    func testBumpingTheFrontWindowDoesNotPublish() {
        let a = window("a", pid: 1)
        registry.applyOrdered([a, window("b", pid: 2)])
        let count = publishedCount()
        registry.bumpWindowToTop(element: a.element, pid: 1)
        XCTAssertEqual(count(), 0)
    }

    func testBumpingPerWindowLeavesSiblingsOfTheSameAppInPlace() {
        let a1 = window("a1", pid: 1)
        let a2 = window("a2", pid: 1)
        let b = window("b", pid: 2)
        registry.applyOrdered([a1, b, a2])
        registry.bumpWindowToTop(element: a2.element, pid: 1)
        XCTAssertEqual(titles(), ["a2", "a1", "b"])
    }

    func testWindowsByRecencyFollowsRegistryOrder() {
        let one = window("one", pid: 1, bundle: "com.same")
        let two = window("two", pid: 1, bundle: "com.same")
        let other = window("other", pid: 2, bundle: "com.other")
        registry.applyOrdered([one, other, two])
        registry.bumpWindowToTop(element: two.element, pid: 1)
        XCTAssertEqual(registry.windowsByRecency(forBundleIdentifier: "com.same").map(\.windowTitle), ["two", "one"])
    }

    func testLookupByBundleIdentifier() {
        registry.applyOrdered([window("a", pid: 1, bundle: "com.a"), window("b", pid: 2, bundle: "com.b"), window("c", pid: 3, bundle: "com.a")])
        XCTAssertEqual(registry.windows(forBundleIdentifier: "com.a").map(\.windowTitle), ["a", "c"])
        XCTAssertTrue(registry.windows(forBundleIdentifier: "com.none").isEmpty)
        XCTAssertTrue(registry.windows(forBundleIdentifier: "").isEmpty)
    }

    // MARK: - Minimized and visible

    func testMinimizedListsOnlyMinimizedWindowsInOrder() {
        registry.applyOrdered([
            window("a", minimized: true), window("b"), window("c", minimized: true),
        ])
        XCTAssertEqual(registry.minimized.map(\.windowTitle), ["a", "c"])
    }

    func testVisibleNeverIncludesMinimizedWindows() {
        registry.applyOrdered([window("a", minimized: true, cgWindowID: 1)])
        XCTAssertTrue(registry.visible.isEmpty)
    }

    func testWindowsTooSmallAreNotCapturable() {
        for size in [CGSize(width: 99, height: 600), CGSize(width: 800, height: 99), CGSize(width: 0, height: 0), CGSize(width: -5, height: -5)] {
            let small = window("s", frame: CGRect(origin: .zero, size: size), cgWindowID: 0x7FFF_FF00)
            XCTAssertFalse(registry.isCapturable(small), "\(size)")
        }
    }

    func testWindowsWithoutACGWindowIDAreNotCapturable() {
        XCTAssertFalse(registry.isCapturable(window("a", cgWindowID: nil)))
    }

    func testWindowsTheWindowServerHasNeverHeardOfAreNotCapturable() {
        XCTAssertFalse(registry.isCapturable(window("a", cgWindowID: 0x7FFF_FF00)))
    }

    func testMinimumTrackedSizeBoundary() {
        XCTAssertTrue(WindowRegistry.isBelowMinimumTrackedSize(CGSize(width: 99.9, height: 100)))
        XCTAssertTrue(WindowRegistry.isBelowMinimumTrackedSize(CGSize(width: 100, height: 99.9)))
        XCTAssertFalse(WindowRegistry.isBelowMinimumTrackedSize(CGSize(width: 100, height: 100)))
        XCTAssertFalse(WindowRegistry.isBelowMinimumTrackedSize(CGSize(width: 5000, height: 5000)))
        XCTAssertTrue(WindowRegistry.isBelowMinimumTrackedSize(.zero))
    }

    func testSwitchableWithMinimizedIncludedKeepsMinimizedWindowsThatHaveAnID() {
        registry.applyOrdered([
            window("min-with-id", minimized: true, cgWindowID: 55),
            window("min-without-id", minimized: true, cgWindowID: nil),
            window("normal-uncapturable", cgWindowID: nil),
        ])
        XCTAssertEqual(registry.switchable(includeMinimized: true).map(\.windowTitle), ["min-with-id"])
    }

    func testSwitchableWithoutMinimizedDropsThemAll() {
        registry.applyOrdered([
            window("min", minimized: true, cgWindowID: 55),
            window("small", frame: CGRect(x: 0, y: 0, width: 10, height: 10), cgWindowID: 1),
        ])
        XCTAssertTrue(registry.switchable(includeMinimized: false).isEmpty)
    }

    func testMinimizedWindowsSkipTheSizeTest() {
        // CGWindowServer often omits bounds for minimized windows, so a
        // minimized window with a tiny or absent frame is still listed.
        registry.applyOrdered([window("min", minimized: true, frame: nil, cgWindowID: 9)])
        XCTAssertEqual(registry.switchable(includeMinimized: true).count, 1)
    }

    // MARK: - Preview invalidation and pid reuse

    private func invalidations() -> () -> [String] {
        var seen: [String] = []
        registry.previewInvalidations.sink { seen.append($0) }.store(in: &cancellables)
        return { seen }
    }

    func testTheFirstFocusHasNothingToInvalidate() {
        let a = window("a", pid: 1)
        registry.applyOrdered([a])
        let seen = invalidations()
        registry.noteFocusedWindow(a.id, pid: 1)
        XCTAssertEqual(seen(), [])
        XCTAssertEqual(registry.lastFocusedWindowIDByPID[1], a.id)
    }

    func testInvalidationNamesThePreviousFocusedWindow() {
        let a = window("a", pid: 1)
        let b = window("b", pid: 1)
        registry.applyOrdered([a, b])
        let seen = invalidations()
        registry.noteFocusedWindow(a.id, pid: 1)
        registry.noteFocusedWindow(b.id, pid: 1)
        XCTAssertEqual(seen(), [a.windowIdentifier])
        XCTAssertEqual(registry.lastFocusedWindowIDByPID[1], b.id)
    }

    func testRefocusingTheSameWindowDoesNotInvalidate() {
        let a = window("a", pid: 1)
        registry.applyOrdered([a])
        registry.noteFocusedWindow(a.id, pid: 1)
        let seen = invalidations()
        registry.noteFocusedWindow(a.id, pid: 1)
        XCTAssertEqual(seen(), [])
    }

    func testInvalidationSkipsAPreviousWindowThatIsGone() {
        let a = window("a", pid: 1)
        let b = window("b", pid: 1)
        registry.applyOrdered([a, b])
        registry.noteFocusedWindow(a.id, pid: 1)
        registry.applyOrdered([b])
        let seen = invalidations()
        registry.noteFocusedWindow(b.id, pid: 1)
        XCTAssertEqual(seen(), [])
    }

    func testAppTerminationClearsTheFocusRecordSoAReusedPidStartsClean() {
        let old = window("old", pid: 500)
        registry.applyOrdered([old])
        registry.noteFocusedWindow(old.id, pid: 500)
        XCTAssertNotNil(registry.lastFocusedWindowIDByPID[500])

        registry.removeWindows(for: 500)
        XCTAssertNil(registry.lastFocusedWindowIDByPID[500])

        // The OS hands pid 500 to a different app with its own window.
        let reused = window("reused", pid: 500, bundle: "com.other")
        registry.applyOrdered([reused])
        let seen = invalidations()
        registry.noteFocusedWindow(reused.id, pid: 500)
        XCTAssertEqual(seen(), [], "a stale record must not invalidate a stranger's preview")
        XCTAssertEqual(registry.windows(forBundleIdentifier: "com.other").count, 1)
        XCTAssertTrue(registry.windows(forBundleIdentifier: "com.app.500").isEmpty)
    }

    func testReusedPidWithoutATerminationNotificationStillReplacesWindowsOnSync() {
        let old = window("old", pid: 600, bundle: "com.old")
        registry.applyOrdered([old])
        let newApp = window("new", pid: 600, bundle: "com.new")
        registry.replaceWindows(forPID: 600, with: [newApp])
        XCTAssertEqual(titles(), ["new"])
        XCTAssertEqual(registry.windows[0].bundleIdentifier, "com.new")
    }

    func testTwoAppsWithTheSamePidSlotAreKeptApartByElement() {
        // Elements, not pids, are identity: two windows that report the same
        // pid are still two windows.
        registry.applyOrdered([window("x", pid: 9), window("y", pid: 9)])
        XCTAssertEqual(registry.windows.count, 2)
    }

    // MARK: - Tracking rules

    func testTheTestHostItselfIsNeverTracked() {
        XCTAssertFalse(registry.shouldTrack(NSRunningApplication.current))
    }

    func testTheDockProcessIsNeverTracked() throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw XCTSkip("Dock is not running")
        }
        XCTAssertFalse(registry.shouldTrack(dock))
    }

    func testARegularAppIsTracked() throws {
        let regular = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let regular else { throw XCTSkip("no other regular app is running") }
        XCTAssertTrue(registry.shouldTrack(regular))
    }

    // MARK: - Window operations on a registry that does not observe

    func testLiveWindowsForAnImpossiblePidIsEmpty() {
        XCTAssertTrue(registry.liveWindows(for: 0).isEmpty)
        XCTAssertTrue(registry.liveWindows(for: -1).isEmpty)
        XCTAssertTrue(registry.liveWindows(for: 2_000_000_000).isEmpty)
    }
}
