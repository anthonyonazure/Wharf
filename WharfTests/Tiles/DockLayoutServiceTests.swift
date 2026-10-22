import Combine
import CoreGraphics
import XCTest
@testable import Wharf

/// `DockLayoutService` holds one dock's chrome measurements. Its logic is the
/// clamp on the content scale and the delta guards that stop SwiftUI from
/// re-rendering on sub-pixel noise. (It has no row or wrap math; that lives in
/// the views.) Each test uses a fresh instance, never `.shared`.
@MainActor
final class DockLayoutServiceTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testDefaults() {
        let layout = DockLayoutService()
        XCTAssertEqual(layout.contentScale, 1)
        XCTAssertFalse(layout.compactsWidgetsForOverflow)
        XCTAssertEqual(layout.chromeSize, .zero)
        XCTAssertEqual(layout.tileCanvasFrame, .zero)
    }

    // MARK: - contentScale

    func testScaleIsClampedToUnitRange() {
        let cases: [(CGFloat, CGFloat)] = [
            (-5, 0), (-0.0001, 0), (0, 0), (0.25, 0.25), (0.5, 0.5), (1, 1), (1.0001, 1), (7, 1),
            (.infinity, 1), (-.infinity, 0), (.greatestFiniteMagnitude, 1), (-.greatestFiniteMagnitude, 0),
        ]
        for (input, expected) in cases {
            let layout = DockLayoutService()
            // Start away from the target so the delta guard does not hide it.
            layout.setContentScale(0.5)
            layout.setContentScale(input)
            XCTAssertEqual(layout.contentScale, expected, accuracy: 0.0000001, "input \(input)")
        }
    }

    func testNaNScaleIsIgnoredAndKeepsTheLastValue() {
        // min(max(nan, 0), 1) is NaN and abs(a - NaN) > eps is false, so the
        // guard swallows it. Pinned so the invariant "never NaN" is explicit.
        let layout = DockLayoutService()
        layout.setContentScale(0.4)
        layout.setContentScale(.nan)
        XCTAssertEqual(layout.contentScale, 0.4, accuracy: 0.0000001)
        XCTAssertFalse(layout.contentScale.isNaN)
    }

    func testSubThresholdScaleChangesAreIgnored() {
        let layout = DockLayoutService()
        layout.setContentScale(0.5)
        layout.setContentScale(0.50005)
        XCTAssertEqual(layout.contentScale, 0.5)
        layout.setContentScale(0.5002)
        XCTAssertEqual(layout.contentScale, 0.5002, accuracy: 0.0000001)
    }

    func testRepeatedScaleDoesNotPublish() {
        let layout = DockLayoutService()
        var emissions = 0
        layout.$contentScale.dropFirst().sink { _ in emissions += 1 }.store(in: &cancellables)
        layout.setContentScale(0.5)
        layout.setContentScale(0.5)
        layout.setContentScale(0.5)
        XCTAssertEqual(emissions, 1)
    }

    func testClampedToSameValuePublishesNothing() {
        let layout = DockLayoutService()
        var emissions = 0
        layout.$contentScale.dropFirst().sink { _ in emissions += 1 }.store(in: &cancellables)
        layout.setContentScale(3)
        layout.setContentScale(100)
        XCTAssertEqual(emissions, 0, "1 -> clamp(3) is still 1")
    }

    func testScaledMultipliesByTheContentScale() {
        let layout = DockLayoutService()
        XCTAssertEqual(layout.scaled(48), 48)
        layout.setContentScale(0.5)
        XCTAssertEqual(layout.scaled(48), 24)
        layout.setContentScale(0)
        XCTAssertEqual(layout.scaled(48), 0)
        XCTAssertEqual(layout.scaled(-10), 0)
    }

    func testScaledPreservesSign() {
        let layout = DockLayoutService()
        layout.setContentScale(0.5)
        XCTAssertEqual(layout.scaled(-8), -4)
    }

    // MARK: - compactsWidgetsForOverflow

    func testCompactFlagTogglesAndIsIdempotent() {
        let layout = DockLayoutService()
        var emissions = 0
        layout.$compactsWidgetsForOverflow.dropFirst().sink { _ in emissions += 1 }.store(in: &cancellables)
        layout.setCompactsWidgetsForOverflow(true)
        layout.setCompactsWidgetsForOverflow(true)
        XCTAssertTrue(layout.compactsWidgetsForOverflow)
        layout.setCompactsWidgetsForOverflow(false)
        XCTAssertFalse(layout.compactsWidgetsForOverflow)
        XCTAssertEqual(emissions, 2)
    }

    // MARK: - chromeSize

    func testChromeSizeChangeAndGuard() {
        let layout = DockLayoutService()
        layout.setChromeSize(CGSize(width: 400, height: 80))
        XCTAssertEqual(layout.chromeSize, CGSize(width: 400, height: 80))
        layout.setChromeSize(CGSize(width: 400.00005, height: 80.00005))
        XCTAssertEqual(layout.chromeSize, CGSize(width: 400, height: 80), "sub-threshold jitter is ignored")
        layout.setChromeSize(CGSize(width: 400, height: 80.01))
        XCTAssertEqual(layout.chromeSize.height, 80.01, accuracy: 0.0000001)
    }

    func testChromeSizeWidthAndHeightAreIndependentTriggers() {
        let widthOnly = DockLayoutService()
        widthOnly.setChromeSize(CGSize(width: 10, height: 10))
        widthOnly.setChromeSize(CGSize(width: 20, height: 10))
        XCTAssertEqual(widthOnly.chromeSize.width, 20)

        let heightOnly = DockLayoutService()
        heightOnly.setChromeSize(CGSize(width: 10, height: 10))
        heightOnly.setChromeSize(CGSize(width: 10, height: 20))
        XCTAssertEqual(heightOnly.chromeSize.height, 20)
    }

    func testChromeSizeAcceptsZeroAndNegativeWithoutTrapping() {
        let layout = DockLayoutService()
        layout.setChromeSize(CGSize(width: 50, height: 50))
        layout.setChromeSize(.zero)
        XCTAssertEqual(layout.chromeSize, .zero)
        layout.setChromeSize(CGSize(width: -1, height: -1))
        XCTAssertEqual(layout.chromeSize, CGSize(width: -1, height: -1))
    }

    // MARK: - tileCanvasFrame

    func testCanvasFrameEachComponentTriggersAnUpdate() {
        let base = CGRect(x: 10, y: 10, width: 100, height: 50)
        let variants = [
            CGRect(x: 20, y: 10, width: 100, height: 50),
            CGRect(x: 10, y: 20, width: 100, height: 50),
            CGRect(x: 10, y: 10, width: 120, height: 50),
            CGRect(x: 10, y: 10, width: 100, height: 70),
        ]
        for variant in variants {
            let layout = DockLayoutService()
            layout.setTileCanvasFrame(base)
            layout.setTileCanvasFrame(variant)
            XCTAssertEqual(layout.tileCanvasFrame, variant)
        }
    }

    func testCanvasFrameIgnoresSubThresholdJitter() {
        let layout = DockLayoutService()
        let base = CGRect(x: 10, y: 10, width: 100, height: 50)
        layout.setTileCanvasFrame(base)
        layout.setTileCanvasFrame(base.offsetBy(dx: 0.00001, dy: -0.00001))
        XCTAssertEqual(layout.tileCanvasFrame, base)
    }

    func testCanvasFrameOfInfiniteRectDoesNotTrap() {
        let layout = DockLayoutService()
        layout.setTileCanvasFrame(.infinite)
        layout.setTileCanvasFrame(.null)
        layout.setTileCanvasFrame(.zero)
        XCTAssertEqual(layout.tileCanvasFrame, .zero)
    }

    // MARK: - Independence

    func testInstancesDoNotShareState() {
        let a = DockLayoutService()
        let b = DockLayoutService()
        a.setContentScale(0.3)
        a.setChromeSize(CGSize(width: 1, height: 2))
        XCTAssertEqual(b.contentScale, 1)
        XCTAssertEqual(b.chromeSize, .zero)
    }
}
