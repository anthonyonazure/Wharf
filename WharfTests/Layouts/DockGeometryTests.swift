import CoreGraphics
import XCTest
@testable import Wharf

/// Magnification math and ramp, chrome growth metrics, and the geometry that
/// keeps maximized windows off the dock strip.
@MainActor
final class DockGeometryTests: LayoutTestCase {

    // MARK: - Magnification model

    private func model(
        base: CGFloat = 48, max: CGFloat = 96, radius: CGFloat = 120,
        strength: CGFloat = 1, cursor: CGFloat? = 0
    ) -> DockMagnificationModel {
        DockMagnificationModel(baseSize: base, maxSize: max, influenceRadius: radius, strength: strength, cursorAxisLocation: cursor)
    }

    func testTileUnderTheCursorReachesTheMaximum() {
        XCTAssertEqual(model(cursor: 200).magnifiedExtent(restSize: 48, restAxisCenter: 200), 96, accuracy: 1e-9)
    }

    func testTileAtTheEdgeOfTheRadiusStaysAtRest() {
        XCTAssertEqual(model(cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 120), 48, accuracy: 1e-9)
    }

    func testTilesBeyondTheRadiusStayAtRest() {
        for distance in [CGFloat(120.01), 200, 5000, 1e9] {
            XCTAssertEqual(model(cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: distance), 48, accuracy: 1e-9)
        }
    }

    func testFalloffNeverIncreasesWithDistance() {
        let m = model(cursor: 0)
        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...240 {
            let extent = m.magnifiedExtent(restSize: 48, restAxisCenter: CGFloat(step) / 2)
            XCTAssertLessThanOrEqual(extent, previous + 1e-9)
            previous = extent
        }
    }

    func testFalloffIsSymmetricAroundTheCursor() {
        let m = model(cursor: 500)
        for offset in stride(from: CGFloat(0), through: 150, by: 10) {
            let left = m.magnifiedExtent(restSize: 48, restAxisCenter: 500 - offset)
            let right = m.magnifiedExtent(restSize: 48, restAxisCenter: 500 + offset)
            XCTAssertEqual(left, right, accuracy: 1e-9)
        }
    }

    func testStrengthScalesTheGrowthLinearly() {
        for strength in stride(from: CGFloat(0), through: 1, by: 0.25) {
            let extent = model(strength: strength, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0)
            XCTAssertEqual(extent, 48 + 48 * strength, accuracy: 1e-9)
        }
    }

    func testExtentStaysBetweenRestAndMaxForStrengthInRange() {
        for strength in stride(from: CGFloat(0), through: 1, by: 0.1) {
            for center in stride(from: CGFloat(-300), through: 300, by: 13) {
                let extent = model(strength: strength, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: center)
                XCTAssertGreaterThanOrEqual(extent, 48 - 1e-9)
                XCTAssertLessThanOrEqual(extent, 96 + 1e-9)
            }
        }
    }

    func testMagnificationIsOffWhenThereIsNothingToDo() {
        XCTAssertEqual(model(strength: 0, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(strength: -1, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(max: 48, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(max: 10, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(radius: 0, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(radius: -5, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(cursor: nil).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
    }

    func testNaNInputsFallBackToTheRestSize() {
        XCTAssertEqual(model(strength: .nan, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(radius: .nan, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(max: .nan, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(cursor: .nan).magnifiedExtent(restSize: 48, restAxisCenter: 0), 48)
        XCTAssertEqual(model(cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: .nan), 48)
    }

    func testInfiniteInputsDoNotProduceNaN() {
        let results = [
            model(cursor: .infinity).magnifiedExtent(restSize: 48, restAxisCenter: 0),
            model(cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: -.infinity),
            model(radius: .infinity, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 10),
            model(max: .infinity, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 100),
        ]
        for value in results { XCTAssertFalse(value.isNaN) }
    }

    func testHugeFiniteValuesStayFinite() {
        let m = model(base: 1e300, max: 2e300, radius: 1e300, strength: 1, cursor: 0)
        XCTAssertTrue(m.magnifiedExtent(restSize: 1e300, restAxisCenter: 1e299).isFinite)
    }

    func testNegativeRestSizeIsHandled() {
        let extent = model(cursor: 0).magnifiedExtent(restSize: -10, restAxisCenter: 0)
        XCTAssertFalse(extent.isNaN)
    }

    func testTheResultIsSafeToTurnIntoAnIntegerForLayout() {
        for strength in [CGFloat(0), 0.5, 1] {
            let extent = model(strength: strength, cursor: 0).magnifiedExtent(restSize: 48, restAxisCenter: 33)
            XCTAssertNotNil(Int(exactly: extent.rounded()))
        }
    }

    // MARK: - Magnification ramp

    private final class Clock {
        var now: CFTimeInterval = 100
    }

    private func makeRamp() -> (DockMagnificationService, Clock) {
        let clock = Clock()
        let service = DockMagnificationService(clock: { clock.now }, drivesRampWithTimer: false)
        return (service, clock)
    }

    func testRampStartsAtRest() {
        let (service, _) = makeRamp()
        XCTAssertEqual(service.strength, 0)
        XCTAssertNil(service.pointerLocation)
        XCTAssertFalse(service.isRamping)
    }

    func testEnteringStoresThePointerAndRampsUpWithEaseOut() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(service.pointerLocation, CGPoint(x: 10, y: 20))
        clock.now += 0.075 // half of the 0.15 s ramp
        service.tick()
        XCTAssertEqual(service.strength, 0.75, accuracy: 1e-9)
        clock.now += 0.075
        service.tick()
        XCTAssertEqual(service.strength, 1, accuracy: 1e-9)
    }

    func testRampNeverOvershoots() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: .zero)
        for _ in 0..<40 {
            clock.now += 0.01
            service.tick()
            XCTAssertGreaterThanOrEqual(service.strength, 0)
            XCTAssertLessThanOrEqual(service.strength, 1)
        }
        XCTAssertEqual(service.strength, 1)
    }

    func testRampIsMonotonicOnTheWayUp() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: .zero)
        var previous: CGFloat = 0
        for _ in 0..<20 {
            clock.now += 0.01
            service.tick()
            XCTAssertGreaterThanOrEqual(service.strength, previous)
            previous = service.strength
        }
    }

    func testLeavingRampsDownAndThenClearsThePointer() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: CGPoint(x: 5, y: 5))
        clock.now += 1
        service.tick()
        XCTAssertEqual(service.strength, 1)

        service.clearPointer()
        clock.now += 0.075
        service.tick()
        XCTAssertEqual(service.strength, 0.25, accuracy: 1e-9)
        XCTAssertNotNil(service.pointerLocation, "the anchor stays while shrinking")

        clock.now += 0.075
        service.tick()
        XCTAssertEqual(service.strength, 0)
        XCTAssertNil(service.pointerLocation)
    }

    func testReversingMidRampStartsFromTheCurrentStrength() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: .zero)
        clock.now += 0.075
        service.tick()
        XCTAssertEqual(service.strength, 0.75, accuracy: 1e-9)
        service.clearPointer()
        clock.now += 0.0001
        service.tick()
        XCTAssertLessThanOrEqual(service.strength, 0.75)
        XCTAssertGreaterThan(service.strength, 0.7)
    }

    func testRepeatedPointerUpdatesDoNotRestartTheRamp() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: CGPoint(x: 0, y: 0))
        clock.now += 0.075
        service.updatePointer(at: CGPoint(x: 50, y: 0))
        clock.now += 0.075
        service.tick()
        XCTAssertEqual(service.strength, 1, accuracy: 1e-9, "the ramp kept its original start time")
    }

    func testSubPixelJitterIsNotPublished() {
        let (service, _) = makeRamp()
        service.updatePointer(at: CGPoint(x: 10, y: 10))
        service.updatePointer(at: CGPoint(x: 10.2, y: 10.2))
        XCTAssertEqual(service.pointerLocation, CGPoint(x: 10, y: 10))
        service.updatePointer(at: CGPoint(x: 10.3, y: 10))
        XCTAssertEqual(service.pointerLocation, CGPoint(x: 10.3, y: 10))
    }

    func testClearingWithoutEverEnteringIsANoOp() {
        let (service, clock) = makeRamp()
        service.clearPointer()
        clock.now += 1
        service.tick()
        XCTAssertEqual(service.strength, 0)
        XCTAssertNil(service.pointerLocation)
    }

    func testClockGoingBackwardsDoesNotMoveTheStrengthOutOfRange() {
        let (service, clock) = makeRamp()
        service.updatePointer(at: .zero)
        clock.now -= 50
        service.tick()
        XCTAssertGreaterThanOrEqual(service.strength, 0)
        XCTAssertLessThanOrEqual(service.strength, 1)
    }

    func testStrengthStaysInRangeUnderAnyEnterLeaveSequence() {
        let (service, clock) = makeRamp()
        var enter = true
        for step in 0..<400 {
            if step % 7 == 0 {
                if enter { service.updatePointer(at: CGPoint(x: CGFloat(step), y: 0)) } else { service.clearPointer() }
                enter.toggle()
            }
            clock.now += 0.013
            service.tick()
            XCTAssertGreaterThanOrEqual(service.strength, 0)
            XCTAssertLessThanOrEqual(service.strength, 1)
        }
    }

    func testRampWithItsRealTimerFinishesOnItsOwn() {
        let service = DockMagnificationService()
        service.updatePointer(at: CGPoint(x: 1, y: 1))
        XCTAssertTrue(service.isRamping)
        let done = expectation(description: "ramp completes")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if service.strength >= 1, !service.isRamping {
                timer.invalidate()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 1.0)
        poll.invalidate()
        XCTAssertEqual(service.strength, 1)
    }

    // MARK: - Chrome metrics

    func testGrowthStartsAtZeroAndStoresChanges() {
        let metrics = DockChromeMetricsService()
        XCTAssertEqual(metrics.alongAxisGrowth, 0)
        metrics.setAlongAxisGrowth(42.5)
        XCTAssertEqual(metrics.alongAxisGrowth, 42.5)
    }

    func testTinyChangesAreIgnored() {
        let metrics = DockChromeMetricsService()
        metrics.setAlongAxisGrowth(10)
        metrics.setAlongAxisGrowth(10.00005)
        XCTAssertEqual(metrics.alongAxisGrowth, 10)
        metrics.setAlongAxisGrowth(10.001)
        XCTAssertEqual(metrics.alongAxisGrowth, 10.001, accuracy: 1e-9)
    }

    func testOnlyRealChangesPublish() {
        let metrics = DockChromeMetricsService()
        var published: [CGFloat] = []
        let token = metrics.$alongAxisGrowth.dropFirst().sink { published.append($0) }
        metrics.setAlongAxisGrowth(5)
        metrics.setAlongAxisGrowth(5)
        metrics.setAlongAxisGrowth(5.00001)
        metrics.setAlongAxisGrowth(8)
        token.cancel()
        XCTAssertEqual(published, [5, 8])
    }

    func testNaNGrowthIsRejected() {
        let metrics = DockChromeMetricsService()
        metrics.setAlongAxisGrowth(12)
        metrics.setAlongAxisGrowth(.nan)
        XCTAssertEqual(metrics.alongAxisGrowth, 12)
    }

    func testGrowthCanReturnToZero() {
        let metrics = DockChromeMetricsService()
        metrics.setAlongAxisGrowth(30)
        metrics.setAlongAxisGrowth(0)
        XCTAssertEqual(metrics.alongAxisGrowth, 0)
    }

    func testInfiniteGrowthIsRejectedLikeNaN() {
        let metrics = DockChromeMetricsService()
        metrics.setAlongAxisGrowth(.infinity)
        XCTAssertTrue(metrics.alongAxisGrowth.isFinite)
    }

    // MARK: - Reservation geometry

    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    private func bottomDock(height: CGFloat = 70) -> CGRect {
        CGRect(x: 0, y: 0, width: 1440, height: height)
    }

    func testFlipYMatchesTheLayoutServiceFlip() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(
            WindowReservationGeometry.flipY(frame, primaryHeight: 900),
            WorkspaceLayoutService.flipY(frame, primaryHeight: 900)
        )
    }

    func testDockSideIsRecognisedOnEveryEdge() {
        XCTAssertEqual(WindowReservationGeometry.side(of: CGRect(x: 0, y: 0, width: 80, height: 875), on: visible), .left)
        XCTAssertEqual(WindowReservationGeometry.side(of: CGRect(x: 1360, y: 0, width: 80, height: 875), on: visible), .right)
        XCTAssertEqual(WindowReservationGeometry.side(of: CGRect(x: 100, y: 0, width: 1200, height: 70), on: visible), .bottom)
        XCTAssertEqual(WindowReservationGeometry.side(of: CGRect(x: 100, y: 805, width: 1200, height: 70), on: visible), .top)
    }

    func testAFullWidthBottomDockIsBottomNotLeftOrRight() {
        XCTAssertEqual(WindowReservationGeometry.side(of: bottomDock(), on: visible), .bottom)
    }

    func testAFloatingDockHasNoSide() {
        XCTAssertNil(WindowReservationGeometry.side(of: CGRect(x: 300, y: 20, width: 800, height: 70), on: visible))
        XCTAssertNil(WindowReservationGeometry.side(of: CGRect(x: 300, y: 300, width: 100, height: 100), on: visible))
    }

    func testEdgeToleranceIsStrictlyLessThanTwoPoints() {
        XCTAssertEqual(WindowReservationGeometry.side(of: CGRect(x: 1.99, y: 0, width: 80, height: 875), on: visible), .left)
        XCTAssertNil(WindowReservationGeometry.side(of: CGRect(x: 2, y: 30, width: 80, height: 700), on: visible))
    }

    func testAShortDockFlushWithTheLeftEdgeIsReadAsALeftDock() {
        // Documented ambiguity: left is tested first, so a narrow bottom
        // strip that starts at the left edge classifies as a left dock.
        let strip = CGRect(x: 0, y: 0, width: 600, height: 70)
        XCTAssertEqual(WindowReservationGeometry.side(of: strip, on: visible), .left)
    }

    func testFlushEdgeCountRunsFromZeroToFour() {
        XCTAssertEqual(WindowReservationGeometry.flushEdgeCount(of: visible, against: visible), 4)
        XCTAssertEqual(WindowReservationGeometry.flushEdgeCount(of: CGRect(x: 0, y: 0, width: 720, height: 875), against: visible), 3)
        XCTAssertEqual(WindowReservationGeometry.flushEdgeCount(of: CGRect(x: 0, y: 0, width: 720, height: 437), against: visible), 2)
        XCTAssertEqual(WindowReservationGeometry.flushEdgeCount(of: CGRect(x: 0, y: 100, width: 720, height: 437), against: visible), 1)
        XCTAssertEqual(WindowReservationGeometry.flushEdgeCount(of: CGRect(x: 100, y: 100, width: 600, height: 400), against: visible), 0)
    }

    func testPushAwayOnEachSide() {
        let window = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(
            WindowReservationGeometry.pushAway(window, from: CGRect(x: 0, y: 0, width: 80, height: 875), on: .left),
            CGRect(x: 80, y: 0, width: 1360, height: 875)
        )
        XCTAssertEqual(
            WindowReservationGeometry.pushAway(window, from: CGRect(x: 1360, y: 0, width: 80, height: 875), on: .right),
            CGRect(x: 0, y: 0, width: 1360, height: 875)
        )
        XCTAssertEqual(
            WindowReservationGeometry.pushAway(window, from: bottomDock(), on: .bottom),
            CGRect(x: 0, y: 70, width: 1440, height: 805)
        )
        XCTAssertEqual(
            WindowReservationGeometry.pushAway(window, from: CGRect(x: 0, y: 805, width: 1440, height: 70), on: .top),
            CGRect(x: 0, y: 0, width: 1440, height: 805)
        )
    }

    func testPushAwayNeverGoesNegative() {
        let inside = CGRect(x: 10, y: 10, width: 40, height: 40)
        let dock = CGRect(x: 0, y: 0, width: 1440, height: 70)
        let result = WindowReservationGeometry.pushAway(inside, from: dock, on: .bottom)
        XCTAssertEqual(result.height, 0)
        let leftDock = CGRect(x: 0, y: 0, width: 200, height: 875)
        XCTAssertEqual(WindowReservationGeometry.pushAway(inside, from: leftDock, on: .left).width, 0)
    }

    func testRectsMatchWithinOnePoint() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(WindowReservationGeometry.rectsMatch(a, CGRect(x: 0.9, y: -0.9, width: 100.5, height: 99.5)))
        XCTAssertFalse(WindowReservationGeometry.rectsMatch(a, CGRect(x: 1, y: 0, width: 100, height: 100)))
        XCTAssertFalse(WindowReservationGeometry.rectsMatch(a, CGRect(x: 0, y: 0, width: 100, height: 102)))
    }

    func testAMaximizedWindowIsShrunkOffTheDock() {
        let target = WindowReservationGeometry.reservedFrame(for: visible, dockFrame: bottomDock(), visibleFrame: visible)
        XCTAssertEqual(target, CGRect(x: 0, y: 70, width: 1440, height: 805))
    }

    func testAHalfTileKeepsItsCrossAxisAnchoring() {
        let leftHalf = CGRect(x: 0, y: 0, width: 720, height: 875)
        let target = WindowReservationGeometry.reservedFrame(for: leftHalf, dockFrame: bottomDock(), visibleFrame: visible)
        XCTAssertEqual(target, CGRect(x: 0, y: 70, width: 720, height: 805))
    }

    func testAFreeFloatingWindowIsLeftAlone() {
        let floating = CGRect(x: 200, y: 20, width: 600, height: 400)
        XCTAssertNil(WindowReservationGeometry.reservedFrame(for: floating, dockFrame: bottomDock(), visibleFrame: visible))
    }

    func testAWindowThatDoesNotTouchTheDockIsLeftAlone() {
        let topHalf = CGRect(x: 0, y: 500, width: 1440, height: 375)
        XCTAssertNil(WindowReservationGeometry.reservedFrame(for: topHalf, dockFrame: bottomDock(), visibleFrame: visible))
    }

    func testAWindowAlreadyClearOfTheDockIsLeftAlone() {
        let clear = CGRect(x: 0, y: 70, width: 1440, height: 805)
        XCTAssertNil(WindowReservationGeometry.reservedFrame(for: clear, dockFrame: bottomDock(), visibleFrame: visible))
    }

    func testAWindowFullyUnderTheDockIsNotCollapsed() {
        let under = CGRect(x: 0, y: 0, width: 1440, height: 60)
        XCTAssertNil(WindowReservationGeometry.reservedFrame(for: under, dockFrame: bottomDock(), visibleFrame: visible))
    }

    func testNoReservationWhenTheDockIsNotAnchored() {
        let floatingDock = CGRect(x: 300, y: 20, width: 800, height: 70)
        XCTAssertNil(WindowReservationGeometry.reservedFrame(for: visible, dockFrame: floatingDock, visibleFrame: visible))
    }

    func testReservationIsIdempotent() {
        let docks: [(CGRect, [CGRect])] = [
            (bottomDock(), [visible, CGRect(x: 0, y: 0, width: 720, height: 875)]),
            (CGRect(x: 0, y: 0, width: 80, height: 875), [visible, CGRect(x: 0, y: 437, width: 1440, height: 438)]),
            (CGRect(x: 1360, y: 0, width: 80, height: 875), [visible, CGRect(x: 720, y: 0, width: 720, height: 875)]),
            (CGRect(x: 0, y: 805, width: 1440, height: 70), [visible, CGRect(x: 0, y: 437, width: 1440, height: 438)]),
        ]
        for (dock, windows) in docks {
            for window in windows {
                guard let first = WindowReservationGeometry.reservedFrame(for: window, dockFrame: dock, visibleFrame: visible) else {
                    XCTFail("expected a target for \(window) against \(dock)")
                    continue
                }
                XCTAssertNil(
                    WindowReservationGeometry.reservedFrame(for: first, dockFrame: dock, visibleFrame: visible),
                    "a second pass must not move \(first) again"
                )
                XCTAssertFalse(first.intersects(dock) && first.intersection(dock).width > 0.5 && first.intersection(dock).height > 0.5)
                XCTAssertTrue(window.contains(first))
            }
        }
    }

    func testReservationWithHostileFramesDoesNotTrap() {
        let hostile = [
            CGRect.zero,
            CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300),
            CGRect(x: -1e300, y: -1e300, width: 5, height: 5),
            CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan),
            CGRect(x: 0, y: 0, width: -100, height: -100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity),
        ]
        for window in hostile {
            for dock in hostile + [bottomDock()] {
                _ = WindowReservationGeometry.reservedFrame(for: window, dockFrame: dock, visibleFrame: visible)
                _ = WindowReservationGeometry.reservedFrame(for: window, dockFrame: bottomDock(), visibleFrame: dock)
            }
        }
    }
}
