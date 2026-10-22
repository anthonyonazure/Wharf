//
//  WindowSnapDragZonesTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/WindowSnapDragZones.swift. Compiled
//  with the geometry file into a small executable, since the Xcode project
//  has no test target. Run: scripts/test-snap-zones.sh
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

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    expect(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

private typealias Z = WindowSnapDragZones

// A 1440 x 900 primary display with a 25 point menu bar and the system Dock
// hidden, and a 1920 x 1080 display to its right, bottoms aligned.
private let primary = Z.Screen(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
)
private let secondary = Z.Screen(
    frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
)
private let single = [primary]
private let pair = [primary, secondary]

private func edge(_ x: CGFloat, _ y: CGFloat, screens: [Z.Screen] = single, speed: CGVector = .zero, hit: CGFloat = 12) -> WindowSnapAction? {
    Z.edgeHit(at: CGPoint(x: x, y: y), screens: screens, velocity: speed, hitZone: hit)?.action
}

private func testEdges() {
    expectEqual(edge(0, 450), .leftHalf, "left wall")
    expectEqual(edge(11, 450), .leftHalf, "inside the left hit zone")
    expectEqual(edge(13, 450), nil, "just outside the left hit zone")
    expectEqual(edge(30, 450, hit: 40), .leftHalf, "a wider hit zone reaches further")
    expectEqual(edge(1439, 450), .rightHalf, "right wall")
    expectEqual(edge(700, 0), .bottomHalf, "bottom edge")
    expectEqual(edge(700, 899), .maximize, "top edge")
    expectEqual(edge(700, 900), .maximize, "top edge at the very top")
    expectEqual(edge(700, 880), .maximize, "the menu bar counts as the top edge")
    expectEqual(edge(700, 860), nil, "below the menu bar and outside the hit zone")
    expectEqual(edge(700, 450), nil, "middle of the screen")
}

private func testCorners() {
    // Horizontal corner length on 1440 wide: min(max(259.2, 96), 180) = 180.
    // Vertical corner length on 900 high: min(max(162, 80), 160) = 160.
    expectEqual(edge(100, 899), .topLeft, "top edge near the left end")
    expectEqual(edge(1300, 899), .topRight, "top edge near the right end")
    expectEqual(edge(181, 899), .maximize, "top edge just past the corner")
    expectEqual(edge(100, 0), .bottomLeft, "bottom edge near the left end")
    expectEqual(edge(1300, 0), .bottomRight, "bottom edge near the right end")
    expectEqual(edge(0, 800), .topLeft, "left edge near the top")
    expectEqual(edge(0, 100), .bottomLeft, "left edge near the bottom")
    expectEqual(edge(1439, 800), .topRight, "right edge near the top")
    expectEqual(edge(1439, 100), .bottomRight, "right edge near the bottom")
    expectEqual(edge(0, 0), .bottomLeft, "the exact corner")
    expectEqual(Z.horizontalCornerLength(for: CGRect(x: 0, y: 0, width: 400, height: 300)), 96, "corner floor on a small display")
}

private func testSeams() {
    // The seam between the displays at x = 1440.
    expectEqual(edge(1439, 450, screens: pair), .rightHalf, "slow at the seam, left display")
    expectEqual(edge(1439, 450, screens: pair, speed: CGVector(dx: 900, dy: 0)), nil, "passing fast across the seam")
    expectEqual(edge(1439, 450, screens: pair, speed: CGVector(dx: 0, dy: 900)), .rightHalf, "fast along the seam still counts")
    expectEqual(edge(1441, 450, screens: pair), .leftHalf, "slow at the seam, right display")
    let hit = Z.edgeHit(at: CGPoint(x: 1441, y: 450), screens: pair, hitZone: 12)
    expectEqual(hit?.screenIndex, 1, "the seam's right side belongs to the right display")
    expectEqual(edge(3359, 450, screens: pair, speed: CGVector(dx: 900, dy: 0)), .rightHalf, "a wall counts at any speed")
    // The right display is taller: above y = 900 its left edge is a wall.
    expectEqual(edge(1440, 950, screens: pair, speed: CGVector(dx: -900, dy: 0)), .topLeft, "left wall above the shorter display")
    expectEqual(edge(2500, 1080, screens: pair), .maximize, "top of the taller display")
    expectEqual(Z.screenIndex(for: CGPoint(x: 1440, y: 10), in: pair.map(\.frame)), 1, "seam point goes to the display holding it")
    expectEqual(Z.screenIndex(for: CGPoint(x: 5000, y: 10), in: pair.map(\.frame)), nil, "far off every display")
}

private func testModifierZones() {
    let area = CGRect(x: 100, y: 50, width: 1000, height: 800)
    func action(_ fx: CGFloat, _ fy: CGFloat) -> WindowSnapAction? {
        Z.modifierAction(at: CGPoint(x: area.minX + fx * area.width, y: area.minY + fy * area.height), in: area)
    }
    expectEqual(action(0.1, 0.5), .leftHalf, "left band")
    expectEqual(action(0.3, 0.5), .leftThird, "left third band")
    expectEqual(action(0.5, 0.5), .centerThird, "center band")
    expectEqual(action(0.7, 0.5), .rightThird, "right third band")
    expectEqual(action(0.9, 0.5), .rightHalf, "right band")
    expectEqual(action(0.1, 0.9), .topLeft, "top left corner zone")
    expectEqual(action(0.5, 0.9), .topHalf, "top band")
    expectEqual(action(0.9, 0.9), .topRight, "top right corner zone")
    expectEqual(action(0.1, 0.1), .bottomLeft, "bottom left corner zone")
    expectEqual(action(0.5, 0.1), .bottomHalf, "bottom band")
    expectEqual(action(0.9, 0.1), .bottomRight, "bottom right corner zone")
    expectEqual(action(1.0, 1.0), .topRight, "the far corner is inside")
    expectEqual(action(-0.5, 0.5), .leftHalf, "left of the area takes the nearest zone")
    expectEqual(action(0.5, 1.2), .topHalf, "over the menu bar takes the top band")
    expectEqual(action(0.5, -0.1), .bottomHalf, "over the dock strip takes the bottom band")
    expectEqual(Z.modifierAction(at: .zero, in: .zero), nil, "an empty area has no zone")

    let zones = Z.modifierZones(in: area)
    expectEqual(zones.count, 11, "eleven zones")
    let covered = zones.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
    expectEqual(covered, area.width * area.height, "zones tile the area exactly")
    for zone in zones {
        let center = CGPoint(x: zone.rect.midX, y: zone.rect.midY)
        expectEqual(Z.modifierAction(at: center, in: area), zone.action, "zone \(zone.action) agrees with the hit test")
    }
}

private func testClassify() {
    let start = CGRect(x: 100, y: 100, width: 600, height: 400)
    func classify(_ frame: CGRect, pointer: CGPoint) -> Z.DragClassification {
        Z.classify(initialFrame: start, currentFrame: frame, pointerStart: CGPoint(x: 300, y: 110), pointerNow: pointer)
    }
    expectEqual(classify(start, pointer: CGPoint(x: 340, y: 110)), .waiting, "window still")
    expectEqual(classify(start.offsetBy(dx: 40, dy: 10), pointer: CGPoint(x: 340, y: 120)), .moving, "window follows the pointer")
    expectEqual(classify(start.offsetBy(dx: -40, dy: 0), pointer: CGPoint(x: 340, y: 110)), .unrelated, "window moves against the pointer")
    expectEqual(classify(CGRect(x: 100, y: 100, width: 640, height: 400), pointer: CGPoint(x: 340, y: 110)), .resizing, "right edge resize")
    // A snapped window shrinks back to its old size as the drag starts.
    expectEqual(classify(CGRect(x: 140, y: 110, width: 400, height: 300), pointer: CGPoint(x: 340, y: 120)), .moving, "restore size while moving")

    let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
    expect(Z.startsAtResizeHandle(CGPoint(x: 100, y: 300), frame: frame), "left border is a resize handle")
    expect(Z.startsAtResizeHandle(CGPoint(x: 108, y: 108), frame: frame), "corner is a resize handle")
    expect(!Z.startsAtResizeHandle(CGPoint(x: 400, y: 112), frame: frame), "title bar is not a resize handle")
    expect(!Z.startsAtResizeHandle(CGPoint(x: 900, y: 300), frame: frame), "far away is not a resize handle")
}

private func testDwell() {
    var dwell = WindowSnapDragDwell<WindowSnapAction>()
    expectEqual(dwell.update(.leftHalf, at: 10, dwell: 0.2), nil, "not armed at once")
    expectEqual(dwell.remaining(at: 10.05, dwell: 0.2).map { ($0 * 100).rounded() }, 15, "time left")
    expectEqual(dwell.update(.leftHalf, at: 10.25, dwell: 0.2), .leftHalf, "armed after the dwell")
    expectEqual(dwell.remaining(at: 10.25, dwell: 0.2), nil, "nothing left once armed")
    expectEqual(dwell.update(.topLeft, at: 10.3, dwell: 0.2), nil, "a new candidate restarts the dwell")
    expectEqual(dwell.update(nil, at: 10.6, dwell: 0.2), nil, "leaving every zone disarms")
    expectEqual(dwell.update(.maximize, at: 11, dwell: 0), .maximize, "zero dwell arms at once")
    dwell.reset()
    expectEqual(dwell.candidate, nil, "reset clears")
}

private func testTrail() {
    var trail = WindowSnapDragPointerTrail()
    expectEqual(trail.velocity(at: 0), .zero, "empty trail is still")
    trail.append(CGPoint(x: 0, y: 0), at: 1.00)
    trail.append(CGPoint(x: 10, y: 0), at: 1.01)
    trail.append(CGPoint(x: 20, y: 0), at: 1.02)
    expect(abs(trail.velocity(at: 1.02).dx - 1000) < 1, "1000 points per second")
    expectEqual(trail.velocity(at: 1.5), .zero, "a pause reads as stopped")
}

private func testModifiers() {
    typealias M = WindowSnapDragModifiers
    expectEqual(M.defaultValue, [.control, .option], "default is Control Option")
    expectEqual(M.defaultValue.displayString, "\u{2303}\u{2325}", "symbols in menu order")
    expectEqual(M([.command, .shift, .control, .option]).displayString, "\u{2303}\u{2325}\u{21E7}\u{2318}", "all four in order")
    // 1 << 8 is a device-dependent bit and 1 << 16 is Caps Lock: both ignored.
    let held = M.control.rawValue | M.option.rawValue | (1 << 8) | (1 << 16)
    expect(M.defaultValue.matches(eventFlags: held), "matches with stray bits")
    expect(!M.defaultValue.matches(eventFlags: held | M.command.rawValue), "an extra modifier does not match")
    expect(!M.defaultValue.matches(eventFlags: M.control.rawValue), "a missing modifier does not match")
    expect(!M.shift.isUsable, "Shift alone is not usable")
    expect(!M.shift.matches(eventFlags: M.shift.rawValue), "Shift alone never matches")
    expectEqual(M(storedValue: nil), .defaultValue, "nothing stored is the default")
    expectEqual(M(storedValue: Int(M.shift.rawValue)), .defaultValue, "an unusable stored set falls back")
    expectEqual(M(storedValue: Int(M([.command, .option]).rawValue)), [.command, .option], "a stored set round trips")
    expectEqual(M(storedValue: -5), .defaultValue, "a negative stored value falls back")
}

private func testSettingsAndTiling() {
    expectEqual(Z.clampedHitZone(0), 2, "hit zone floor")
    expectEqual(Z.clampedHitZone(500), 40, "hit zone ceiling")
    expectEqual(Z.clampedHitZone(.nan), 12, "hit zone default on garbage")
    expectEqual(Z.clampedDwell(-1), 0, "dwell floor")
    expectEqual(Z.clampedDwell(9), 1, "dwell ceiling")
    expect(Z.systemTilingEnabled(valueFor: { _ in nil }, displaysSpan: false), "unwritten tiling prefs mean on")
    expect(!Z.systemTilingEnabled(valueFor: { _ in false }, displaysSpan: false), "all switched off")
    expect(!Z.systemTilingEnabled(valueFor: { _ in true }, displaysSpan: true), "spanning displays make tiling inert")
}

@main
struct WindowSnapDragZonesTests {
    static func main() {
        testEdges()
        testCorners()
        testSeams()
        testModifierZones()
        testClassify()
        testDwell()
        testTrail()
        testModifiers()
        testSettingsAndTiling()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
