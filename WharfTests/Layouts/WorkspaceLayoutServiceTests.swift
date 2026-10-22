import XCTest
@testable import Wharf

/// Capture, restore, undo, the launch-and-wait loop and persistence of the
/// layout service, driven against a fake desk so no real window is touched.
@MainActor
final class WorkspaceLayoutServiceTests: LayoutTestCase {
    private var desk: FakeDesk!
    private var defaults: UserDefaults!
    private var service: WorkspaceLayoutService!

    override func setUp() {
        super.setUp()
        desk = FakeDesk()
        defaults = makeDefaults()
        service = WorkspaceLayoutService(defaults: defaults, environment: desk.environment())
    }

    private func reloaded() -> WorkspaceLayoutService {
        WorkspaceLayoutService(defaults: defaults, environment: desk.environment())
    }

    // MARK: - Capture

    func testCaptureStoresVisibleWindowsAndSkipsMinimizedOnes() {
        desk.windows = [
            FakeWindows.make(title: "Shown"),
            FakeWindows.make(title: "Hidden", minimized: true),
        ]
        service.capture(name: "Work")
        XCTAssertEqual(service.layouts.count, 1)
        XCTAssertEqual(service.layouts[0].placements.map(\.windowTitle), ["Shown"])
    }

    func testCaptureConvertsAXCoordinatesToScreenCoordinates() {
        desk.windows = [FakeWindows.make(frame: CGRect(x: 100, y: 50, width: 800, height: 600))]
        service.capture(name: "Work")
        XCTAssertEqual(service.layouts[0].placements[0].frame, CGRect(x: 100, y: 250, width: 800, height: 600))
    }

    func testCaptureSkipsWindowsWithDegenerateFrames() {
        let frames: [CGRect?] = [
            nil,
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: 0, y: 0, width: 0, height: 0),
        ]
        desk.windows = frames.map { FakeWindows.make(frame: $0) }
        service.capture(name: "Empty")
        XCTAssertTrue(service.layouts.isEmpty, "a capture of only degenerate windows must not save an empty layout")
    }

    func testCaptureNormalizesNegativeSizedFrames() {
        // CGRect reports the absolute extent of a negative size, so such a
        // frame is stored with its positive width and height.
        desk.windows = [FakeWindows.make(frame: CGRect(x: 400, y: 100, width: -100, height: -50))]
        service.capture(name: "Negative")
        let frame = service.layouts[0].placements[0].frame
        XCTAssertEqual(frame.width, 100)
        XCTAssertEqual(frame.height, 50)
    }

    func testCaptureKeepsGoodWindowsAlongsideDegenerateOnes() {
        desk.windows = [
            FakeWindows.make(title: "Bad", frame: CGRect(x: 0, y: 0, width: 0, height: 0)),
            FakeWindows.make(title: "Good"),
            FakeWindows.make(title: "Missing", frame: nil),
        ]
        service.capture(name: "Mixed")
        XCTAssertEqual(service.layouts[0].placements.map(\.windowTitle), ["Good"])
    }

    func testCaptureWithNoWindowsSavesNothing() {
        service.capture(name: "Nothing")
        XCTAssertTrue(service.layouts.isEmpty)
        XCTAssertNil(defaults.data(forKey: WorkspaceLayoutService.defaultsKey))
    }

    func testCaptureWithNoDisplaysSavesNothing() {
        desk.displays = []
        desk.windows = [FakeWindows.make()]
        service.capture(name: "Headless")
        XCTAssertTrue(service.layouts.isEmpty)
    }

    func testCaptureRecordsWhichDisplayEachWindowIsOn() {
        desk.windows = [
            FakeWindows.make(title: "Left", frame: CGRect(x: 100, y: 100, width: 400, height: 300)),
            // AX y is measured from the top of the primary display.
            FakeWindows.make(title: "Right", frame: CGRect(x: 1600, y: 100, width: 400, height: 300)),
        ]
        service.capture(name: "Two screens")
        let uuids = Dictionary(uniqueKeysWithValues: service.layouts[0].placements.map { ($0.windowTitle, $0.displayUUID) })
        XCTAssertEqual(uuids["Left"] ?? nil, "DISPLAY-A")
        XCTAssertEqual(uuids["Right"] ?? nil, "DISPLAY-B")
    }

    func testCaptureOfWindowStraddlingTwoDisplaysUsesTheBiggerShare() {
        desk.windows = [FakeWindows.make(frame: CGRect(x: 1340, y: 100, width: 400, height: 300))]
        service.capture(name: "Seam")
        XCTAssertEqual(service.layouts[0].placements[0].displayUUID, "DISPLAY-B")
    }

    func testCaptureOfOffscreenWindowRecordsNoDisplay() {
        desk.windows = [FakeWindows.make(frame: CGRect(x: 20_000, y: 20_000, width: 400, height: 300))]
        service.capture(name: "Far away")
        XCTAssertNil(service.layouts[0].placements[0].displayUUID)
    }

    func testCaptureListsEachRunningAppOnceInSortedOrder() {
        desk.windows = [
            FakeWindows.make(bundle: "com.zeta", title: "1"),
            FakeWindows.make(bundle: "com.alpha", title: "2"),
            FakeWindows.make(bundle: "com.zeta", title: "3"),
            FakeWindows.make(bundle: "com.mid", title: "4"),
        ]
        service.capture(name: "Apps")
        XCTAssertEqual(service.layouts[0].bundleIdentifiers, ["com.alpha", "com.mid", "com.zeta"])
    }

    func testCaptureKeepsWindowOrder() {
        desk.windows = (0..<8).map { FakeWindows.make(title: "W\($0)") }
        service.capture(name: "Ordered")
        XCTAssertEqual(service.layouts[0].placements.map(\.windowTitle), (0..<8).map { "W\($0)" })
    }

    func testCaptureUnderAnExistingNameReplacesItInPlace() {
        desk.windows = [FakeWindows.make(title: "First")]
        service.capture(name: "A")
        service.capture(name: "B")
        desk.windows = [FakeWindows.make(title: "Second")]
        service.capture(name: "A")
        XCTAssertEqual(service.layouts.map(\.name), ["A", "B"])
        XCTAssertEqual(service.layouts[0].placements.map(\.windowTitle), ["Second"])
    }

    func testCaptureUnderADifferentNameAppends() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "A")
        service.capture(name: "B")
        service.capture(name: "C")
        XCTAssertEqual(service.layouts.map(\.name), ["A", "B", "C"])
    }

    func testLayoutNamesAreCaseSensitive() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "Work")
        service.capture(name: "work")
        XCTAssertEqual(service.layouts.count, 2)
    }

    func testCaptureAcceptsEmptyAndWhitespaceNames() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "")
        service.capture(name: "   ")
        XCTAssertEqual(service.layouts.map(\.name), ["", "   "])
    }

    func testCaptureRecapturingKeepsTheLayoutIdentity() {
        desk.windows = [FakeWindows.make(title: "First")]
        service.capture(name: "Work")
        let originalID = service.layouts[0].id
        desk.windows = [FakeWindows.make(title: "Second")]
        service.capture(name: "Work")
        XCTAssertEqual(service.layouts[0].id, originalID)
    }

    func testEachNewLayoutGetsItsOwnID() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "A")
        service.capture(name: "B")
        XCTAssertEqual(Set(service.layouts.map(\.id)).count, 2)
    }

    func testCaptureWithHugeFramesDoesNotTrap() {
        desk.windows = [
            FakeWindows.make(frame: CGRect(x: -1e300, y: -1e300, width: 1e300, height: 1e300)),
            FakeWindows.make(frame: CGRect(x: 1e15, y: 1e15, width: 5, height: 5)),
        ]
        service.capture(name: "Huge")
        XCTAssertEqual(service.layouts.count, 1)
    }

    func testCaptureWithInfiniteFrameStaysInMemoryAndKeepsPriorSavedLayouts() {
        desk.windows = [FakeWindows.make(title: "Fine")]
        service.capture(name: "Keep")
        let stored = defaults.data(forKey: WorkspaceLayoutService.defaultsKey)

        desk.windows = [FakeWindows.make(title: "Odd", frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100))]
        service.capture(name: "Odd")
        // JSON cannot hold infinity, so the save is skipped and the earlier blob is untouched.
        XCTAssertEqual(defaults.data(forKey: WorkspaceLayoutService.defaultsKey), stored)
    }

    func testCapturePersistsAndAnotherServiceSeesIt() {
        desk.windows = [FakeWindows.make(title: "Saved")]
        service.capture(name: "Persisted")
        let other = reloaded()
        XCTAssertEqual(other.layouts, service.layouts)
    }

    func testCapturePlacementTitleIsStoredVerbatim() {
        desk.windows = [FakeWindows.make(title: "  padded \u{1F4C4} title\n")]
        service.capture(name: "Raw")
        XCTAssertEqual(service.layouts[0].placements[0].windowTitle, "  padded \u{1F4C4} title\n")
    }

    // MARK: - Restore

    private func captureTwoWindowLayout() -> WorkspaceLayout {
        desk.windows = [
            FakeWindows.make(bundle: "com.a", title: "A1", frame: CGRect(x: 10, y: 40, width: 500, height: 400)),
            FakeWindows.make(bundle: "com.b", title: "B1", frame: CGRect(x: 600, y: 50, width: 600, height: 500)),
        ]
        service.capture(name: "Two")
        return service.layouts[0]
    }

    func testRestoreMovesEachWindowToItsStoredFrameInAXSpace() {
        let layout = captureTwoWindowLayout()
        desk.clearResizeLog()
        let result = service.restore(layout)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.missed, 0)
        XCTAssertEqual(desk.resizeLog[0].frame, CGRect(x: 10, y: 40, width: 500, height: 400))
        XCTAssertEqual(desk.resizeLog[2].frame, CGRect(x: 600, y: 50, width: 600, height: 500))
    }

    func testRestoreAppliesEveryPlacementTwice() {
        let layout = captureTwoWindowLayout()
        desk.clearResizeLog()
        service.restore(layout)
        XCTAssertEqual(desk.resizeLog.count, 4)
        XCTAssertEqual(desk.resizeLog[0].window.windowIdentifier, desk.resizeLog[1].window.windowIdentifier)
        XCTAssertEqual(desk.resizeLog[0].frame, desk.resizeLog[1].frame)
        XCTAssertEqual(desk.resizeLog[2].window.windowIdentifier, desk.resizeLog[3].window.windowIdentifier)
    }

    func testRestoreCountsAWindowAsMovedWhenOnlyTheSecondPassSucceeds() {
        let layout = captureTwoWindowLayout()
        desk.clearResizeLog()
        // Call numbers: the first window's passes are 1 and 2, the second's 3 and 4.
        desk.resizeResult = { _, call in call.isMultiple(of: 2) }
        let result = service.restore(layout)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.missed, 0)
    }

    func testRestoreCountsAWindowAsMovedWhenOnlyTheFirstPassSucceeds() {
        let layout = captureTwoWindowLayout()
        desk.resizeResult = { _, call in !call.isMultiple(of: 2) }
        desk.clearResizeLog()
        let result = service.restore(layout)
        XCTAssertEqual(result.moved, 2)
    }

    func testRestoreCountsAWindowAsMissedWhenBothPassesFail() {
        let layout = captureTwoWindowLayout()
        desk.resizeResult = { _, _ in false }
        let result = service.restore(layout)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.missed, 2)
    }

    func testRestoreCountsPlacementsWithoutAWindowAsMissed() {
        let layout = makeLayout(placements: [makePlacement(bundle: "com.gone"), makePlacement(bundle: "com.gone2")])
        let result = service.restore(layout)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.missed, 2)
        XCTAssertTrue(desk.resizeLog.isEmpty)
    }

    func testRestoreDoesNotMoveMinimizedWindows() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A", minimized: true)]
        let layout = makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")])
        let result = service.restore(layout)
        XCTAssertEqual(result.missed, 1)
        XCTAssertTrue(desk.resizeLog.isEmpty)
    }

    func testRestoreMatchesByTitleThenByPosition() {
        let first = FakeWindows.make(bundle: "com.a", title: "One")
        let second = FakeWindows.make(bundle: "com.a", title: "Two")
        desk.windows = [first, second]
        let layout = makeLayout(placements: [
            makePlacement(bundle: "com.a", title: "Two", frame: CGRect(x: 0, y: 100, width: 300, height: 300)),
            makePlacement(bundle: "com.a", title: "Renamed", frame: CGRect(x: 400, y: 100, width: 300, height: 300)),
        ])
        service.restore(layout)
        XCTAssertEqual(desk.resizeLog[0].window.windowIdentifier, second.windowIdentifier)
        XCTAssertEqual(desk.resizeLog[2].window.windowIdentifier, first.windowIdentifier)
    }

    func testRestoreLeavesExtraWindowsAlone() {
        let target = FakeWindows.make(bundle: "com.a", title: "Target")
        desk.windows = [target] + (0..<4).map { FakeWindows.make(bundle: "com.a", title: "Extra \($0)") }
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "Target")]))
        let touched = Set(desk.resizeLog.map(\.window.windowIdentifier))
        XCTAssertEqual(touched, [target.windowIdentifier])
    }

    func testRestoreSendsWindowsFromAnUnpluggedDisplayToTheMainOne() {
        desk.displays = [.primary]
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let placement = makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 2000, y: 100, width: 600, height: 400), display: "DISPLAY-B")
        service.restore(makeLayout(placements: [placement]))
        let applied = desk.resizeLog[0].frame
        // Convert back to screen space to check it landed on the primary display.
        let ns = WorkspaceLayoutService.flipY(applied, primaryHeight: 900)
        XCTAssertTrue(LayoutDisplay.primary.visibleFrame.contains(ns))
    }

    func testRestoreClampsAFrameOffAnAttachedDisplayBackOnto() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let placement = makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 100, y: 100, width: 600, height: 400), display: "DISPLAY-B")
        service.restore(makeLayout(placements: [placement]))
        let ns = WorkspaceLayoutService.flipY(desk.resizeLog[0].frame, primaryHeight: 900)
        XCTAssertTrue(LayoutDisplay.right.visibleFrame.contains(ns))
    }

    func testRestoreWithNoDisplaysDoesNothing() {
        desk.displays = []
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let result = service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")]))
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.missed, 0)
        XCTAssertTrue(desk.resizeLog.isEmpty)
    }

    func testRestoreOfEmptyLayoutMovesNothing() {
        desk.windows = [FakeWindows.make()]
        let result = service.restore(makeLayout(placements: []))
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.missed, 0)
    }

    func testRestoreFlagsItselfAsRestoringOnlyWhileRunning() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        var observed: [Bool] = []
        desk.onResize = { [unowned self] in observed.append(self.service.isRestoring) }
        XCTAssertFalse(service.isRestoring)
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")]))
        XCTAssertEqual(observed, [true, true])
        XCTAssertFalse(service.isRestoring)
    }

    func testRestoreResizesInPlacementOrder() {
        desk.windows = (0..<5).map { FakeWindows.make(bundle: "com.a", title: "W\($0)") }
        let placements = [3, 0, 4, 1, 2].map { makePlacement(bundle: "com.a", title: "W\($0)") }
        service.restore(makeLayout(placements: placements))
        let titles = stride(from: 0, to: desk.resizeLog.count, by: 2).map { desk.resizeLog[$0].window.windowTitle }
        XCTAssertEqual(titles, ["W3", "W0", "W4", "W1", "W2"])
    }

    func testRestoreNormalizesNegativeSizedStoredFrames() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let placement = makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 500, y: 300, width: -200, height: -100), display: nil)
        service.restore(makeLayout(placements: [placement]))
        let applied = desk.resizeLog[0].frame
        XCTAssertGreaterThanOrEqual(applied.size.width, 0)
        XCTAssertGreaterThanOrEqual(applied.size.height, 0)
    }

    func testRestoreShrinksAnOversizedStoredFrameToTheDisplay() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let placement = makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 0, y: 0, width: 9000, height: 9000), display: "DISPLAY-A")
        service.restore(makeLayout(placements: [placement]))
        let applied = desk.resizeLog[0].frame
        XCTAssertLessThanOrEqual(applied.width, LayoutDisplay.primary.visibleFrame.width)
        XCTAssertLessThanOrEqual(applied.height, LayoutDisplay.primary.visibleFrame.height)
    }

    func testRestoreWithHostileFramesDoesNotTrap() {
        desk.windows = (0..<4).map { FakeWindows.make(bundle: "com.a", title: "W\($0)") }
        let frames = [
            CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300),
            CGRect(x: -1e300, y: -1e300, width: -1e300, height: -1e300),
            CGRect.zero,
            CGRect(x: 0, y: 0, width: -1, height: -1),
        ]
        let placements = frames.enumerated().map { makePlacement(bundle: "com.a", title: "W\($0.offset)", frame: $0.element, display: "DISPLAY-A") }
        let result = service.restore(makeLayout(placements: placements))
        XCTAssertEqual(result.moved + result.missed, 4)
    }

    func testRestoreDoesNotCollapseAWindowToZeroSize() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let placement = makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 100, y: 100, width: 0, height: 0), display: nil)
        service.restore(makeLayout(placements: [placement]))
        XCTAssertTrue(desk.resizeLog.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
    }

    func testRestoreMatchesAcrossManyWindows() {
        desk.windows = (0..<60).map { FakeWindows.make(bundle: "com.app\($0 % 6)", title: "W\($0)") }
        service.capture(name: "Big")
        desk.clearResizeLog()
        let result = service.restore(service.layouts[0])
        XCTAssertEqual(result.moved, 60)
        XCTAssertEqual(desk.resizeLog.count, 120)
    }

    // MARK: - Undo

    func testRestoreRecordsTheArrangementItReplaced() throws {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A", frame: CGRect(x: 10, y: 40, width: 300, height: 200))]
        let layout = makeLayout(placements: [makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 500, y: 500, width: 300, height: 200))])
        service.restore(layout)
        let snapshot = try XCTUnwrap(service.undoSnapshot)
        XCTAssertEqual(snapshot.placements.count, 1)
        XCTAssertEqual(snapshot.placements[0].frame, CGRect(x: 10, y: 660, width: 300, height: 200))
        XCTAssertEqual(snapshot.id, "undo")
    }

    func testUndoPutsWindowsBack() {
        let window = FakeWindows.make(bundle: "com.a", title: "A", frame: CGRect(x: 10, y: 40, width: 300, height: 200))
        desk.windows = [window]
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A", frame: CGRect(x: 500, y: 500, width: 300, height: 200))]))
        desk.clearResizeLog()
        let result = service.undoLastRestore()
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(desk.resizeLog[0].frame, CGRect(x: 10, y: 40, width: 300, height: 200))
    }

    func testUndoCanOnlyBeUsedOnce() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")]))
        XCTAssertNotNil(service.undoSnapshot)
        service.undoLastRestore()
        XCTAssertNil(service.undoSnapshot)
        let second = service.undoLastRestore()
        XCTAssertEqual(second.moved, 0)
        XCTAssertEqual(second.missed, 0)
    }

    func testUndoDoesNotRecordAnotherUndo() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")]))
        service.undoLastRestore()
        XCTAssertNil(service.undoSnapshot, "undoing must not make the two arrangements ping-pong")
    }

    func testRestoreWithoutUndoCaptureKeepsTheExistingSnapshot() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        let layout = makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")])
        service.restore(layout)
        let before = service.undoSnapshot
        service.restore(layout, capturesUndo: false)
        XCTAssertEqual(service.undoSnapshot, before)
    }

    func testUndoWithoutAnyRestoreDoesNothing() {
        desk.windows = [FakeWindows.make()]
        let result = service.undoLastRestore()
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(desk.resizeLog.isEmpty)
    }

    func testUndoSnapshotIsNeverPersisted() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A")]
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")]))
        XCTAssertNotNil(service.undoSnapshot)
        XCTAssertNil(reloaded().undoSnapshot)
        XCTAssertTrue(reloaded().layouts.isEmpty)
    }

    func testSecondRestoreReplacesTheUndoSnapshot() {
        let window = FakeWindows.make(bundle: "com.a", title: "A", frame: CGRect(x: 10, y: 40, width: 300, height: 200))
        desk.windows = [window]
        let layout = makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")])
        service.restore(layout)
        let first = service.undoSnapshot
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A", frame: CGRect(x: 700, y: 300, width: 300, height: 200))]
        service.restore(layout)
        XCTAssertNotEqual(service.undoSnapshot, first)
    }

    func testUndoSnapshotSkipsMinimizedAndDegenerateWindows() {
        desk.windows = [
            FakeWindows.make(bundle: "com.a", title: "Shown"),
            FakeWindows.make(bundle: "com.a", title: "Min", minimized: true),
            FakeWindows.make(bundle: "com.a", title: "Flat", frame: CGRect(x: 0, y: 0, width: 0, height: 0)),
        ]
        service.restore(makeLayout(placements: [makePlacement(bundle: "com.a", title: "Shown")]))
        XCTAssertEqual(service.undoSnapshot?.placements.map(\.windowTitle), ["Shown"])
    }

    func testUndoSnapshotGoesStaleWhenTheDeskIsEmptyAtTheNextRestore() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "A", frame: CGRect(x: 10, y: 40, width: 300, height: 200))]
        let layout = makeLayout(placements: [makePlacement(bundle: "com.a", title: "A")])
        service.restore(layout)
        let afterFirst = service.undoSnapshot
        desk.windows = []
        service.restore(layout)
        XCTAssertNotEqual(service.undoSnapshot, afterFirst)
    }

    // MARK: - Launching missing apps

    private func layoutNeeding(_ bundles: [String]) -> WorkspaceLayout {
        makeLayout(
            placements: bundles.map { makePlacement(bundle: $0, title: "W") },
            bundles: bundles
        )
    }

    func testLaunchMissingAppsLaunchesOnlyWhatIsNotRunning() {
        desk.running = ["com.a"]
        desk.launchable = ["com.a", "com.b", "com.c"]
        let launched = service.launchMissingApps(for: layoutNeeding(["com.a", "com.b", "com.c"]))
        XCTAssertEqual(launched, 2)
        XCTAssertEqual(Set(desk.launched), ["com.b", "com.c"])
    }

    func testLaunchMissingAppsSkipsAppsThatAreNotInstalled() {
        desk.launchable = ["com.b"]
        let launched = service.launchMissingApps(for: layoutNeeding(["com.a", "com.b"]))
        XCTAssertEqual(launched, 1)
        XCTAssertEqual(desk.launched, ["com.b"])
    }

    func testLaunchMissingAppsWithEverythingRunningLaunchesNothing() {
        desk.running = ["com.a", "com.b"]
        desk.launchable = ["com.a", "com.b"]
        XCTAssertEqual(service.launchMissingApps(for: layoutNeeding(["com.a", "com.b"])), 0)
        XCTAssertTrue(desk.launched.isEmpty)
    }

    func testLaunchAndRestoreRestoresRightAwayWhenNothingNeedsLaunching() {
        desk.running = ["com.a"]
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "W")]
        service.launchAndRestore(layoutNeeding(["com.a"]))
        XCTAssertFalse(desk.resizeLog.isEmpty)
        XCTAssertTrue(desk.scheduled.isEmpty)
    }

    func testLaunchAndRestoreRestoresRightAwayWhenMissingAppsAreNotInstalled() {
        desk.windows = [FakeWindows.make(bundle: "com.a", title: "W")]
        desk.running = ["com.a"]
        service.launchAndRestore(layoutNeeding(["com.a", "com.notinstalled"]))
        XCTAssertFalse(desk.resizeLog.isEmpty)
        XCTAssertTrue(desk.scheduled.isEmpty)
    }

    func testLaunchAndRestoreWaitsUntilTheLaunchedAppHasAWindow() {
        desk.launchable = ["com.new"]
        let layout = layoutNeeding(["com.new"])
        service.launchAndRestore(layout)
        XCTAssertEqual(desk.launched, ["com.new"])
        XCTAssertTrue(desk.resizeLog.isEmpty)
        XCTAssertEqual(desk.scheduled.count, 1)

        // Two polls with no window yet: still waiting.
        desk.runNextScheduled()
        desk.runNextScheduled()
        XCTAssertTrue(desk.resizeLog.isEmpty)

        desk.windows = [FakeWindows.make(bundle: "com.new", title: "W")]
        desk.runNextScheduled()
        XCTAssertFalse(desk.resizeLog.isEmpty)
        XCTAssertTrue(desk.scheduled.isEmpty, "no further polling once restored")
    }

    func testLaunchAndRestorePollsEveryHalfSecond() {
        desk.launchable = ["com.new"]
        service.launchAndRestore(layoutNeeding(["com.new"]))
        XCTAssertEqual(desk.scheduled.map(\.delay), [0.5])
        desk.runNextScheduled()
        XCTAssertEqual(desk.scheduled.map(\.delay), [0.5])
    }

    func testLaunchAndRestoreGivesUpAtTheDeadlineAndRestoresWhatItCan() {
        desk.launchable = ["com.new"]
        desk.windows = [FakeWindows.make(bundle: "com.old", title: "W")]
        desk.running = ["com.old"]
        let layout = makeLayout(
            placements: [makePlacement(bundle: "com.old", title: "W"), makePlacement(bundle: "com.new", title: "W")],
            bundles: ["com.new", "com.old"]
        )
        service.launchAndRestore(layout, timeout: 15)
        desk.runNextScheduled()
        XCTAssertTrue(desk.resizeLog.isEmpty)

        desk.clock = desk.clock.addingTimeInterval(15)
        desk.runNextScheduled()
        XCTAssertFalse(desk.resizeLog.isEmpty, "the deadline restores whatever windows exist")
        XCTAssertTrue(desk.scheduled.isEmpty)
    }

    func testLaunchAndRestoreDoesNotWaitForAppsThatWereAlreadyRunning() {
        // com.a is running with no windows; com.b is launched and has one.
        desk.running = ["com.a"]
        desk.launchable = ["com.b"]
        service.launchAndRestore(layoutNeeding(["com.a", "com.b"]))
        desk.windows = [FakeWindows.make(bundle: "com.b", title: "W")]
        desk.runNextScheduled()
        XCTAssertFalse(desk.resizeLog.isEmpty)
    }

    func testCancelPendingRestoreStopsAWaitingPlacement() {
        desk.launchable = ["com.new"]
        service.launchAndRestore(layoutNeeding(["com.new"]))
        service.cancelPendingRestore()
        desk.windows = [FakeWindows.make(bundle: "com.new", title: "W")]
        desk.runNextScheduled()
        XCTAssertTrue(desk.resizeLog.isEmpty)
        XCTAssertTrue(desk.scheduled.isEmpty, "a cancelled poll does not reschedule")
    }

    func testANewRestoreSupersedesAWaitingPlacement() {
        desk.launchable = ["com.new"]
        service.launchAndRestore(layoutNeeding(["com.new"]))
        desk.windows = [FakeWindows.make(bundle: "com.new", title: "W")]
        service.restore(layoutNeeding(["com.new"]))
        let movesBefore = desk.resizeLog.count
        desk.runNextScheduled()
        XCTAssertEqual(desk.resizeLog.count, movesBefore, "the stale poll must not restore again")
    }

    func testTheLatestLaunchAndRestoreWins() {
        desk.launchable = ["com.one", "com.two"]
        let first = makeLayout(name: "First", placements: [makePlacement(bundle: "com.one", title: "W")], bundles: ["com.one"])
        let second = makeLayout(name: "Second", placements: [makePlacement(bundle: "com.two", title: "W", frame: CGRect(x: 5, y: 5, width: 100, height: 100))], bundles: ["com.two"])
        service.launchAndRestore(first)
        service.launchAndRestore(second)
        desk.windows = [
            FakeWindows.make(bundle: "com.one", title: "W"),
            FakeWindows.make(bundle: "com.two", title: "W"),
        ]
        while desk.runNextScheduled() {}
        let moved = Set(desk.resizeLog.map(\.window.bundleIdentifier))
        XCTAssertEqual(moved, ["com.two"])
    }

    // MARK: - Management

    func testDeleteRemovesTheLayoutAndPersists() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "A")
        service.capture(name: "B")
        service.delete(service.layouts[0])
        XCTAssertEqual(service.layouts.map(\.name), ["B"])
        XCTAssertEqual(reloaded().layouts.map(\.name), ["B"])
    }

    func testDeleteOfAnUnknownLayoutChangesNothing() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "A")
        service.delete(makeLayout(id: "not-there", name: "Ghost"))
        XCTAssertEqual(service.layouts.count, 1)
    }

    func testRenameKeepsTheIDAndPersists() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "Old")
        let original = service.layouts[0]
        service.rename(original, to: "New")
        XCTAssertEqual(service.layouts[0].id, original.id)
        XCTAssertEqual(service.layouts[0].name, "New")
        XCTAssertEqual(reloaded().layouts[0].name, "New")
    }

    func testRenameOfAnUnknownLayoutChangesNothing() {
        desk.windows = [FakeWindows.make()]
        service.capture(name: "A")
        service.rename(makeLayout(id: "nope"), to: "Z")
        XCTAssertEqual(service.layouts.map(\.name), ["A"])
    }

    func testRenamingOntoAnExistingNameCreatesADuplicateAndCaptureHitsTheFirst() {
        desk.windows = [FakeWindows.make(title: "Original")]
        service.capture(name: "A")
        service.capture(name: "B")
        service.rename(service.layouts[1], to: "A")
        XCTAssertEqual(service.layouts.map(\.name), ["A", "A"])

        desk.windows = [FakeWindows.make(title: "Updated")]
        service.capture(name: "A")
        XCTAssertEqual(service.layouts.count, 2)
        XCTAssertEqual(service.layouts[0].placements[0].windowTitle, "Updated")
        XCTAssertEqual(service.layouts[1].placements[0].windowTitle, "Original")
    }

    func testDuplicateIDsAreRemovedTogether() {
        let first = makeLayout(id: "same", name: "One", placements: [makePlacement()])
        let second = makeLayout(id: "same", name: "Two", placements: [makePlacement()])
        defaults.set(try! JSONEncoder().encode([first, second, makeLayout(id: "other", name: "Three")]), forKey: WorkspaceLayoutService.defaultsKey)
        let loaded = reloaded()
        XCTAssertEqual(loaded.layouts.count, 3)
        loaded.delete(first)
        XCTAssertEqual(loaded.layouts.map(\.name), ["Three"])
    }

    // MARK: - Persistence

    func testFreshDefaultsStartEmpty() {
        XCTAssertTrue(service.layouts.isEmpty)
    }

    func testCorruptStoredBlobStartsEmptyAndIsLeftUntouched() {
        let junk = Data("{not json".utf8)
        defaults.set(junk, forKey: WorkspaceLayoutService.defaultsKey)
        let loaded = reloaded()
        XCTAssertTrue(loaded.layouts.isEmpty)
        XCTAssertEqual(defaults.data(forKey: WorkspaceLayoutService.defaultsKey), junk)
    }

    func testTruncatedStoredBlobStartsEmpty() throws {
        let full = try JSONEncoder().encode([makeLayout(placements: [makePlacement()])])
        defaults.set(full.prefix(full.count / 2), forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
    }

    func testStoredValueOfTheWrongTypeStartsEmpty() {
        defaults.set("a string", forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
        defaults.set(42, forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
        defaults.set(["a", "b"], forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
    }

    func testStoredDictionaryInsteadOfArrayStartsEmpty() {
        defaults.set(Data(#"{"id":"a","name":"x","placements":[],"bundleIdentifiers":[]}"#.utf8), forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
    }

    func testOneUnreadableLayoutDropsTheWholeListInMemory() {
        let good = try! JSONEncoder().encode(makeLayout(name: "Good", placements: [makePlacement()]))
        let blob = Data("[".utf8) + good + Data(#",{"id":"bad"}]"#.utf8)
        defaults.set(blob, forKey: WorkspaceLayoutService.defaultsKey)
        XCTAssertTrue(reloaded().layouts.isEmpty)
        XCTAssertEqual(defaults.data(forKey: WorkspaceLayoutService.defaultsKey), blob, "loading must not rewrite the blob")
    }

    func testLayoutsSurviveRepeatedSaveAndLoadCycles() {
        desk.windows = (0..<6).map { FakeWindows.make(bundle: "com.app\($0)", title: "W\($0)") }
        service.capture(name: "Cycle")
        var current = service!
        let expected = current.layouts
        for _ in 0..<10 {
            current = reloaded()
            XCTAssertEqual(current.layouts, expected)
            current.rename(current.layouts[0], to: "Cycle")
        }
        XCTAssertEqual(current.layouts, expected)
    }

    func testStoredOrderIsPreservedAcrossReload() {
        desk.windows = [FakeWindows.make()]
        for name in ["z", "a", "m", "b"] { service.capture(name: name) }
        XCTAssertEqual(reloaded().layouts.map(\.name), ["z", "a", "m", "b"])
    }

    func testServiceNeverTouchesTheStandardDefaultsDomain() {
        let key = WorkspaceLayoutService.defaultsKey
        let before = UserDefaults.standard.data(forKey: key)
        desk.windows = [FakeWindows.make()]
        service.capture(name: "Isolated")
        service.rename(service.layouts[0], to: "Renamed")
        service.delete(service.layouts[0])
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), before)
    }

    func testManyLayoutsPersist() {
        desk.windows = [FakeWindows.make()]
        for index in 0..<200 { service.capture(name: "Layout \(index)") }
        XCTAssertEqual(reloaded().layouts.count, 200)
    }
}
