import XCTest
@testable import Wharf

/// The size-lock logic of WindowActionsService against a scripted window list
/// and a recording resize, plus the window switcher's selection arithmetic.
@MainActor
final class WindowActionsServiceTests: LayoutTestCase {
    private var windows: [AppWindow] = []
    private var resizes: [(window: AppWindow, frame: CGRect)] = []
    private var resizeSucceeds = true
    private var service: WindowActionsService!

    override func setUp() {
        super.setUp()
        windows = []
        resizes = []
        resizeSucceeds = true
        service = WindowActionsService(
            windows: { [unowned self] in self.windows },
            resize: { [unowned self] window, frame in
                self.resizes.append((window, frame))
                return self.resizeSucceeds
            },
            usesEnforcementTimer: false,
            isProcessRunning: { _ in true }
        )
    }

    private func make(
        _ title: String = "W",
        frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
        element: AXUIElement? = nil
    ) -> AppWindow {
        FakeWindows.make(title: title, frame: frame, element: element)
    }

    /// The same window (same element) after it was resized or moved.
    private func resized(_ window: AppWindow, to frame: CGRect?) -> AppWindow {
        FakeWindows.make(
            bundle: window.bundleIdentifier, title: window.windowTitle, frame: frame,
            pid: window.processIdentifier, element: window.element
        )
    }

    // MARK: - Locking

    func testLockingRecordsTheWindow() {
        let window = make()
        service.toggleSizeLock(window)
        XCTAssertTrue(service.isSizeLocked(window))
        XCTAssertEqual(service.sizeLockedWindowIDs, [window.windowIdentifier])
    }

    func testTogglingTwiceUnlocks() {
        let window = make()
        service.toggleSizeLock(window)
        service.toggleSizeLock(window)
        XCTAssertFalse(service.isSizeLocked(window))
        XCTAssertTrue(service.sizeLockedWindowIDs.isEmpty)
    }

    func testAWindowWithoutAFrameCannotBeLocked() {
        let window = make(frame: nil)
        service.toggleSizeLock(window)
        XCTAssertFalse(service.isSizeLocked(window))
    }

    func testLocksAreIndependentPerWindow() {
        let a = make("a")
        let b = make("b")
        service.toggleSizeLock(a)
        XCTAssertTrue(service.isSizeLocked(a))
        XCTAssertFalse(service.isSizeLocked(b))
        service.toggleSizeLock(b)
        service.toggleSizeLock(a)
        XCTAssertFalse(service.isSizeLocked(a))
        XCTAssertTrue(service.isSizeLocked(b))
    }

    func testLockIdentityIsTheElementNotTheSnapshot() {
        let window = make()
        service.toggleSizeLock(window)
        XCTAssertTrue(service.isSizeLocked(resized(window, to: CGRect(x: 0, y: 0, width: 5, height: 5))))
    }

    // MARK: - Enforcing

    func testEnforcePutsBackTheLockedSizeKeepingTheOrigin() {
        let original = make(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        service.toggleSizeLock(original)
        windows = [resized(original, to: CGRect(x: 150, y: 120, width: 1000, height: 700))]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes[0].frame, CGRect(x: 150, y: 120, width: 800, height: 600))
    }

    func testEnforceLeavesAWindowAtItsLockedSizeAlone() {
        let original = make()
        service.toggleSizeLock(original)
        windows = [original]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
    }

    func testEnforceToleratesAWobbleOfTwoPoints() {
        let original = make(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        service.toggleSizeLock(original)
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: 802, height: 598))]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: 802.01, height: 600))]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 1)
    }

    func testEnforceFixesEitherDimension() {
        let original = make(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        service.toggleSizeLock(original)
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: 800, height: 650))]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 1)
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: 900, height: 600))]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 2)
    }

    func testEnforceOnlyTouchesLockedWindows() {
        let locked = make("locked")
        let free = make("free")
        service.toggleSizeLock(locked)
        windows = [
            resized(locked, to: CGRect(x: 0, y: 0, width: 10, height: 10)),
            resized(free, to: CGRect(x: 0, y: 0, width: 10, height: 10)),
        ]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.map(\.window.windowIdentifier), [locked.windowIdentifier])
    }

    func testEnforceKeepsEachWindowsOwnLockedSize() {
        let a = make("a", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let b = make("b", frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        service.toggleSizeLock(a)
        service.toggleSizeLock(b)
        windows = [
            resized(a, to: CGRect(x: 0, y: 0, width: 500, height: 500)),
            resized(b, to: CGRect(x: 0, y: 0, width: 500, height: 500)),
        ]
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.first { $0.window.windowTitle == "a" }?.frame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(resizes.first { $0.window.windowTitle == "b" }?.frame.size, CGSize(width: 900, height: 700))
    }

    func testUnlockedWindowIsNoLongerEnforced() {
        let window = make()
        service.toggleSizeLock(window)
        service.toggleSizeLock(window)
        windows = [resized(window, to: CGRect(x: 0, y: 0, width: 10, height: 10))]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
    }

    func testEnforceWithoutLocksDoesNothing() {
        windows = [make()]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
    }

    func testAFailedResizeKeepsTheLock() {
        let original = make()
        service.toggleSizeLock(original)
        resizeSucceeds = false
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: 10, height: 10))]
        service.enforceLockedSizes()
        XCTAssertTrue(service.isSizeLocked(original))
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 2, "it keeps trying while the window stays wrong")
    }

    func testEnforceSkipsAWindowWhoseFrameIsUnknown() {
        let original = make()
        service.toggleSizeLock(original)
        windows = [resized(original, to: nil)]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
        XCTAssertTrue(service.isSizeLocked(original))
    }

    func testEnforceIgnoresNaNSizes() {
        let original = make()
        service.toggleSizeLock(original)
        windows = [resized(original, to: CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat.nan))]
        service.enforceLockedSizes()
        XCTAssertTrue(resizes.isEmpty)
    }

    func testLocksForWindowsThatAreGoneAreDropped() {
        let gone = make("gone")
        let kept = make("kept")
        service.toggleSizeLock(gone)
        service.toggleSizeLock(kept)
        windows = [kept]
        service.enforceLockedSizes()
        XCTAssertFalse(service.isSizeLocked(gone))
        XCTAssertTrue(service.isSizeLocked(kept))
    }

    func testALockSurvivesTheAppBeingHiddenAndShown() {
        // Hiding an app removes its windows from the registry for a while.
        let window = make()
        service.toggleSizeLock(window)
        windows = []
        service.enforceLockedSizes()
        windows = [window]
        XCTAssertTrue(service.isSizeLocked(window))
    }

    func testEnforceHandlesManyLocks() {
        let all = (0..<200).map { make("w\($0)", frame: CGRect(x: 0, y: 0, width: 400, height: 300)) }
        all.forEach { service.toggleSizeLock($0) }
        windows = all.map { resized($0, to: CGRect(x: 0, y: 0, width: 401, height: 305)) }
        service.enforceLockedSizes()
        XCTAssertEqual(resizes.count, 200)
    }

    // MARK: - Switcher selection arithmetic

    func testWrappedIndexStaysInRange() {
        for count in 1...12 {
            for index in -50...50 {
                let wrapped = WindowSwitcherService.wrappedIndex(index, count: count)
                XCTAssertTrue((0..<count).contains(wrapped), "index \(index) count \(count)")
            }
        }
    }

    func testWrappedIndexWrapsBothWays() {
        XCTAssertEqual(WindowSwitcherService.wrappedIndex(5, count: 5), 0)
        XCTAssertEqual(WindowSwitcherService.wrappedIndex(-1, count: 5), 4)
        XCTAssertEqual(WindowSwitcherService.wrappedIndex(-5, count: 5), 0)
        XCTAssertEqual(WindowSwitcherService.wrappedIndex(7, count: 5), 2)
        XCTAssertEqual(WindowSwitcherService.wrappedIndex(3, count: 1), 0)
    }

    func testWrappedIndexWithExtremeValuesDoesNotTrap() {
        for index in [Int.max, Int.min, Int.max - 1, Int.min + 1] {
            for count in [1, 2, 7, 256] {
                let wrapped = WindowSwitcherService.wrappedIndex(index, count: count)
                XCTAssertTrue((0..<count).contains(wrapped))
            }
        }
    }

    func testInitialSelectionGoingForwardPicksTheSecondWindow() {
        XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 5, direction: 1), 1)
        XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 2, direction: 1), 1)
    }

    func testInitialSelectionGoingBackwardPicksTheLastWindow() {
        XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 5, direction: -1), 4)
        XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 2, direction: -1), 1)
    }

    func testInitialSelectionWithOneOrNoWindows() {
        for direction in [-1, 1] {
            XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 1, direction: direction), 0)
            XCTAssertEqual(WindowSwitcherService.initialSelectionIndex(count: 0, direction: direction), 0)
        }
    }

    func testSelectionAfterRemovalSlidesIntoThePlaceOfTheRemovedRow() {
        XCTAssertEqual(WindowSwitcherService.selectionIndexAfterRemoving(at: 0, remainingCount: 3), 0)
        XCTAssertEqual(WindowSwitcherService.selectionIndexAfterRemoving(at: 1, remainingCount: 3), 1)
        XCTAssertEqual(WindowSwitcherService.selectionIndexAfterRemoving(at: 2, remainingCount: 3), 2)
    }

    func testSelectionAfterRemovingTheLastRowMovesUp() {
        XCTAssertEqual(WindowSwitcherService.selectionIndexAfterRemoving(at: 3, remainingCount: 3), 2)
        XCTAssertEqual(WindowSwitcherService.selectionIndexAfterRemoving(at: 99, remainingCount: 3), 2)
    }
}
