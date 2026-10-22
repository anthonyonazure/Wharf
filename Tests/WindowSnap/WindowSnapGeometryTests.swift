//
//  WindowSnapGeometryTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/WindowSnapGeometry.swift. The Xcode
//  project has no test target, so this compiles with the geometry file into a
//  small executable. Run: scripts/test-snap-geometry.sh
//

import CoreGraphics
import Foundation

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

private func expectRect(_ actual: CGRect, _ expected: CGRect, _ message: String, line: Int = #line) {
    expect(WindowSnapGeometry.isClose(actual, expected, tolerance: 0.5),
           "\(message): got \(actual), expected \(expected)", line: line)
}

private typealias G = WindowSnapGeometry

// A 1200 x 900 usable area at an offset origin, so every test also proves the
// math is relative to the area and not to zero.
private let area = CGRect(x: 100, y: 50, width: 1200, height: 900)
private let current = CGRect(x: 300, y: 300, width: 400, height: 300)

private func target(_ action: WindowSnapAction, gap: CGFloat = 0, in a: CGRect = area) -> CGRect {
    G.targetRect(for: action, current: current, area: a, gap: gap)
}

private func testHalves() {
    expectRect(target(.leftHalf), CGRect(x: 100, y: 50, width: 600, height: 900), "left half")
    expectRect(target(.rightHalf), CGRect(x: 700, y: 50, width: 600, height: 900), "right half")
    expectRect(target(.topHalf), CGRect(x: 100, y: 500, width: 1200, height: 450), "top half is high Y")
    expectRect(target(.bottomHalf), CGRect(x: 100, y: 50, width: 1200, height: 450), "bottom half")
    expectRect(target(.centerHalf), CGRect(x: 400, y: 50, width: 600, height: 900), "center half")
}

private func testThirds() {
    expectRect(target(.leftThird), CGRect(x: 100, y: 50, width: 400, height: 900), "left third")
    expectRect(target(.centerThird), CGRect(x: 500, y: 50, width: 400, height: 900), "center third")
    expectRect(target(.rightThird), CGRect(x: 900, y: 50, width: 400, height: 900), "right third")
    expectRect(target(.leftTwoThirds), CGRect(x: 100, y: 50, width: 800, height: 900), "left two thirds")
    expectRect(target(.centerTwoThirds), CGRect(x: 300, y: 50, width: 800, height: 900), "center two thirds")
    expectRect(target(.rightTwoThirds), CGRect(x: 500, y: 50, width: 800, height: 900), "right two thirds")
    expectRect(target(.topThird), CGRect(x: 100, y: 650, width: 1200, height: 300), "top third")
    expectRect(target(.middleThird), CGRect(x: 100, y: 350, width: 1200, height: 300), "middle third")
    expectRect(target(.bottomThird), CGRect(x: 100, y: 50, width: 1200, height: 300), "bottom third")
    expectRect(target(.topTwoThirds), CGRect(x: 100, y: 350, width: 1200, height: 600), "top two thirds")
    expectRect(target(.middleTwoThirds), CGRect(x: 100, y: 200, width: 1200, height: 600), "middle two thirds")
    expectRect(target(.bottomTwoThirds), CGRect(x: 100, y: 50, width: 1200, height: 600), "bottom two thirds")
}

private func testQuartersSixthsCorners() {
    expectRect(target(.leftQuarter), CGRect(x: 100, y: 50, width: 300, height: 900), "left quarter")
    expectRect(target(.leftMiddleQuarter), CGRect(x: 400, y: 50, width: 300, height: 900), "left middle quarter")
    expectRect(target(.rightMiddleQuarter), CGRect(x: 700, y: 50, width: 300, height: 900), "right middle quarter")
    expectRect(target(.rightQuarter), CGRect(x: 1000, y: 50, width: 300, height: 900), "right quarter")
    expectRect(target(.topQuarter), CGRect(x: 100, y: 725, width: 1200, height: 225), "top quarter")
    expectRect(target(.upperMiddleQuarter), CGRect(x: 100, y: 500, width: 1200, height: 225), "upper middle quarter")
    expectRect(target(.lowerMiddleQuarter), CGRect(x: 100, y: 275, width: 1200, height: 225), "lower middle quarter")
    expectRect(target(.bottomQuarter), CGRect(x: 100, y: 50, width: 1200, height: 225), "bottom quarter")

    expectRect(target(.topLeftSixth), CGRect(x: 100, y: 500, width: 400, height: 450), "top left sixth")
    expectRect(target(.topCenterSixth), CGRect(x: 500, y: 500, width: 400, height: 450), "top center sixth")
    expectRect(target(.topRightSixth), CGRect(x: 900, y: 500, width: 400, height: 450), "top right sixth")
    expectRect(target(.bottomLeftSixth), CGRect(x: 100, y: 50, width: 400, height: 450), "bottom left sixth")
    expectRect(target(.bottomCenterSixth), CGRect(x: 500, y: 50, width: 400, height: 450), "bottom center sixth")
    expectRect(target(.bottomRightSixth), CGRect(x: 900, y: 50, width: 400, height: 450), "bottom right sixth")

    expectRect(target(.topLeft), CGRect(x: 100, y: 500, width: 600, height: 450), "top left")
    expectRect(target(.topRight), CGRect(x: 700, y: 500, width: 600, height: 450), "top right")
    expectRect(target(.bottomLeft), CGRect(x: 100, y: 50, width: 600, height: 450), "bottom left")
    expectRect(target(.bottomRight), CGRect(x: 700, y: 50, width: 600, height: 450), "bottom right")
}

private func testWholeScreenActions() {
    expectRect(target(.maximize), area, "maximize fills the area")
    expectRect(target(.maximizeWithMargin), CGRect(x: 160, y: 95, width: 1080, height: 810), "maximize with 5% margin")
    expectRect(target(.center), CGRect(x: 500, y: 350, width: 400, height: 300), "center keeps size")

    let huge = CGRect(x: 0, y: 0, width: 5000, height: 5000)
    let centered = G.targetRect(for: .center, current: huge, area: area)
    expectRect(centered, area, "center shrinks an oversized window to the area")

    expectRect(target(.restore), current, "restore is not computed here")
    expectRect(target(.nextDisplay), current, "display moves are not computed here")
}

private func testGaps() {
    let gap: CGFloat = 20
    let left = target(.leftHalf, gap: gap)
    let right = target(.rightHalf, gap: gap)
    expect(abs(right.minX - left.maxX - gap) < 0.5, "two halves end up exactly one gap apart (\(left), \(right))")
    expect(abs(left.minX - (area.minX + gap)) < 0.5, "left half is one gap from the left edge")
    expect(abs(right.maxX - (area.maxX - gap)) < 0.5, "right half is one gap from the right edge")
    expect(abs(left.minY - (area.minY + gap)) < 0.5, "gap at the bottom edge")
    expect(abs(left.maxY - (area.maxY - gap)) < 0.5, "gap at the top edge")

    let top = target(.topHalf, gap: gap)
    let bottom = target(.bottomHalf, gap: gap)
    expect(abs(top.minY - bottom.maxY - gap) < 0.5, "top and bottom halves one gap apart")

    let thirds = [target(.leftThird, gap: gap), target(.centerThird, gap: gap), target(.rightThird, gap: gap)]
    expect(abs(thirds[1].minX - thirds[0].maxX - gap) < 1, "thirds are one gap apart (left, center)")
    expect(abs(thirds[2].minX - thirds[1].maxX - gap) < 1, "thirds are one gap apart (center, right)")

    let maximized = target(.maximize, gap: gap)
    expectRect(maximized, area.insetBy(dx: gap, dy: gap), "maximize keeps the screen gap only")

    let noGap = target(.leftHalf, gap: 0)
    expectRect(noGap, CGRect(x: 100, y: 50, width: 600, height: 900), "zero gap changes nothing")

    let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
    let squeezed = G.screenGapFrame(tiny, gap: 40)
    expect(squeezed.width >= 80 && squeezed.height >= 80, "an oversized gap never inverts a small area")

    expect(G.clampedGap(-5) == 0, "gap clamps at 0")
    expect(G.clampedGap(99) == 40, "gap clamps at 40")
    expect(G.clampedGap(.nan) == 0, "a corrupt gap reads as 0")
}

private func testDockStrip() {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let bottomDock = CGRect(x: 0, y: 0, width: 1000, height: 70)
    expect(G.dockEdge(of: bottomDock, in: visible) == .bottom, "full-width dock at the bottom")
    expectRect(G.subtractingDock(bottomDock, from: visible), CGRect(x: 0, y: 70, width: 1000, height: 730), "bottom strip removed")

    let shortBottomDock = CGRect(x: 300, y: 0, width: 400, height: 60)
    expectRect(G.subtractingDock(shortBottomDock, from: visible), CGRect(x: 0, y: 60, width: 1000, height: 740), "a centered bottom dock still takes its full-width strip")

    let leftDock = CGRect(x: 0, y: 100, width: 64, height: 600)
    expect(G.dockEdge(of: leftDock, in: visible) == .left, "left dock")
    expectRect(G.subtractingDock(leftDock, from: visible), CGRect(x: 64, y: 0, width: 936, height: 800), "left strip removed")

    let rightDock = CGRect(x: 940, y: 0, width: 60, height: 800)
    expect(G.dockEdge(of: rightDock, in: visible) == .right, "full-height right dock")
    expectRect(G.subtractingDock(rightDock, from: visible), CGRect(x: 0, y: 0, width: 940, height: 800), "right strip removed")

    let topDock = CGRect(x: 0, y: 750, width: 1000, height: 50)
    expect(G.dockEdge(of: topDock, in: visible) == .top, "top dock")
    expectRect(G.subtractingDock(topDock, from: visible), CGRect(x: 0, y: 0, width: 1000, height: 750), "top strip removed")

    let cornerDock = CGRect(x: 0, y: 0, width: 300, height: 50)
    expect(G.dockEdge(of: cornerDock, in: visible) == .bottom, "corner dock goes to its thin side")

    let floating = CGRect(x: 300, y: 300, width: 200, height: 60)
    expect(G.dockEdge(of: floating, in: visible) == nil, "a floating dock has no edge")
    expectRect(G.subtractingDock(floating, from: visible), visible, "a floating dock removes nothing")

    expectRect(G.subtractingDock(nil, from: visible), visible, "a hidden dock removes nothing")

    let otherScreen = CGRect(x: 2000, y: 0, width: 1000, height: 70)
    expectRect(G.subtractingDock(otherScreen, from: visible), visible, "a dock on another screen removes nothing")

    // The dock reaching past the visible frame (for example under the menu
    // bar strip) still counts as anchored.
    let overhanging = CGRect(x: -5, y: -5, width: 1010, height: 75)
    expectRect(G.subtractingDock(overhanging, from: visible), CGRect(x: 0, y: 70, width: 1000, height: 730), "an overhanging dock still subtracts")

    // End to end: a snapped half never reaches into the dock.
    let usable = G.subtractingDock(bottomDock, from: visible)
    let half = G.targetRect(for: .bottomHalf, current: current, area: usable, gap: 10)
    expect(half.minY >= bottomDock.maxY, "bottom half stays above the dock (\(half))")
    let full = G.targetRect(for: .maximize, current: current, area: usable)
    expect(full.minY >= bottomDock.maxY, "maximize stays above the dock")
}

private func testAnchoring() {
    let t = CGRect(x: 700, y: 50, width: 600, height: 900)
    let anchored = G.anchoredRect(for: .rightHalf, target: t, actualSize: CGSize(width: 700, height: 900), area: area)
    expect(abs(anchored.maxX - area.maxX) < 0.5, "a window wider than the right half keeps its right edge")

    let top = CGRect(x: 100, y: 500, width: 1200, height: 450)
    let topAnchored = G.anchoredRect(for: .topHalf, target: top, actualSize: CGSize(width: 1200, height: 300), area: area)
    expect(abs(topAnchored.maxY - top.maxY) < 0.5, "a short top half keeps its top edge")

    expect(G.overshoots(CGSize(width: 601, height: 900), target: CGSize(width: 600, height: 900)), "one point wider overshoots")
    expect(!G.overshoots(CGSize(width: 600.4, height: 900), target: CGSize(width: 600, height: 900)), "rounding does not overshoot")
}

private func testDisplayMoves() {
    let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let destination = CGRect(x: 1000, y: 0, width: 2000, height: 1600)

    let window = CGRect(x: 100, y: 200, width: 400, height: 300)
    expectRect(G.rectForDisplay(current: window, source: source, destination: destination),
               CGRect(x: 1200, y: 400, width: 800, height: 600), "position and size scale proportionally")

    let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 800)
    expectRect(G.rectForDisplay(current: leftHalf, source: source, destination: destination),
               CGRect(x: 1000, y: 0, width: 1000, height: 1600), "a left half stays a left half")

    expectRect(G.rectForDisplay(current: source, source: source, destination: destination),
               destination, "a maximized window stays maximized")

    let smaller = CGRect(x: -800, y: 0, width: 800, height: 600)
    let offRight = CGRect(x: 900, y: 700, width: 300, height: 300)
    let moved = G.rectForDisplay(current: offRight, source: source, destination: smaller)
    expect(smaller.contains(moved), "a moved window is clamped fully on screen (\(moved))")

    let frames = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: -1000, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]
    expect(G.adjacentDisplayIndex(currentIndex: 0, frames: frames, forward: true) == 2, "next display is to the right")
    expect(G.adjacentDisplayIndex(currentIndex: 0, frames: frames, forward: false) == 1, "previous display is to the left")
    expect(G.adjacentDisplayIndex(currentIndex: 2, frames: frames, forward: true) == 1, "next wraps to the leftmost")
    expect(G.adjacentDisplayIndex(currentIndex: 1, frames: frames, forward: false) == 2, "previous wraps to the rightmost")
    expect(G.adjacentDisplayIndex(currentIndex: 0, frames: [frames[0]], forward: true) == nil, "one display has no neighbor")

    expect(G.indexOfLargestOverlap(CGRect(x: 900, y: 100, width: 300, height: 300), in: frames) == 2,
           "a straddling window belongs to the screen it mostly covers")
}

private func testFlip() {
    let ax = CGRect(x: 10, y: 20, width: 300, height: 200)
    let ns = G.flipY(ax, primaryHeight: 1000)
    expectRect(ns, CGRect(x: 10, y: 780, width: 300, height: 200), "AX to AppKit")
    expectRect(G.flipY(ns, primaryHeight: 1000), ax, "flip is its own inverse")
}

private func testHistory() {
    var history = WindowSnapHistory<String>()
    let a = CGRect(x: 0, y: 0, width: 100, height: 100)
    let b = CGRect(x: 50, y: 50, width: 200, height: 200)
    let c = CGRect(x: 10, y: 10, width: 300, height: 300)

    history.record(a, for: "w1")
    history.record(b, for: "w1")
    history.record(b, for: "w1")
    expect(history.count(for: "w1") == 2, "a repeated frame is recorded once")

    expect(history.popPrevious(for: "w1", current: c) == b, "restore returns the newest pre-snap frame")
    expect(history.popPrevious(for: "w1", current: c) == a, "restore walks back")
    expect(history.popPrevious(for: "w1", current: c) == nil, "then runs out")

    history.record(a, for: "w2")
    expect(history.popPrevious(for: "w2", current: a) == nil, "a frame equal to the current one is skipped")

    history.record(a, for: "w3")
    expect(history.popPrevious(for: "other", current: a) == nil, "windows are independent")

    for i in 0..<30 {
        history.record(CGRect(x: CGFloat(i * 10), y: 0, width: 100, height: 100), for: "w4")
    }
    expect(history.count(for: "w4") == WindowSnapHistory<String>.perWindowLimit, "history is bounded per window")

    history.removeStale(keeping: ["w4"])
    expect(history.count(for: "w3") == 0 && history.count(for: "w4") > 0, "closed windows are forgotten")
}

private func testShortcuts() {
    expect(WindowSnapShortcuts.resolved(stored: nil as Int?, isCleared: { $0 == 0 }, fallback: 7) == 7, "nothing stored uses the default")
    expect(WindowSnapShortcuts.resolved(stored: 3, isCleared: { $0 == 0 }, fallback: 7) == 3, "stored wins")
    expect(WindowSnapShortcuts.resolved(stored: 0, isCleared: { $0 == 0 }, fallback: 7) == nil, "cleared stays cleared")

    let assigned: [WindowSnapAction: String] = [.leftHalf: "L", .rightHalf: "R"]
    let reserved = [(name: "Window Switcher", shortcut: "TAB")]
    expect(WindowSnapShortcuts.conflict(for: "L", excluding: .rightHalf, assigned: assigned, reserved: reserved) == .action(.leftHalf),
           "another action's shortcut conflicts")
    expect(WindowSnapShortcuts.conflict(for: "L", excluding: .leftHalf, assigned: assigned, reserved: reserved) == nil,
           "re-recording an action's own shortcut is fine")
    expect(WindowSnapShortcuts.conflict(for: "TAB", excluding: .leftHalf, assigned: assigned, reserved: reserved) == .reserved("Window Switcher"),
           "a Wharf shortcut conflicts")
    expect(WindowSnapShortcuts.conflict(for: "X", excluding: nil, assigned: assigned, reserved: reserved) == nil, "a free shortcut is fine")
}

private func testActionTable() {
    let ids = WindowSnapAction.allCases.map(\.hotKeyID)
    expect(Set(ids).count == ids.count, "hot key ids are unique")
    for action in WindowSnapAction.allCases {
        expect(WindowSnapAction(hotKeyID: action.hotKeyID) == action, "hot key id round trips for \(action)")
        expect(action.title.range(of: "\u{2014}") == nil && action.title.range(of: "\u{2013}") == nil, "no dashes in \(action.title)")
    }
    let grouped = WindowSnapAction.Group.allCases.flatMap(\.actions)
    expect(grouped.count == WindowSnapAction.allCases.count, "every action is in exactly one group")
}

@main
struct WindowSnapGeometryTests {
    static func main() {
        testHalves()
        testThirds()
        testQuartersSixthsCorners()
        testWholeScreenActions()
        testGaps()
        testDockStrip()
        testAnchoring()
        testDisplayMoves()
        testFlip()
        testHistory()
        testShortcuts()
        testActionTable()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
