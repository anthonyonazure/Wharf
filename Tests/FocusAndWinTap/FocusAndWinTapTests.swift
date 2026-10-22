//
//  FocusAndWinTapTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/FocusAndWinTapLogic.swift. The Xcode
//  project has no test target, so this compiles with the logic file into a
//  small executable. Run: scripts/test-focus-and-wintap.sh
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

// MARK: - Dwell

private func testDelayClamp() {
    expect(FocusFollowsMouseTiming.clampedDelay(0) == 100, "below range clamps to 100")
    expect(FocusFollowsMouseTiming.clampedDelay(5_000) == 2_000, "above range clamps to 2000")
    expect(FocusFollowsMouseTiming.clampedDelay(300) == 300, "in range is kept")
    expect(FocusFollowsMouseTiming.defaultDelayMilliseconds == 300, "default is 300 ms")
}

private func testDwell() {
    var state = HoverDwellState()
    expect(!state.hasPendingEvaluation, "nothing pending before any movement")
    expect(state.nextEvaluation(at: 10, delayMilliseconds: 300) == nil, "no evaluation without movement")

    state.recordMovement(to: CGPoint(x: 10, y: 10), at: 1.0)
    expect(state.nextEvaluation(at: 1.2, delayMilliseconds: 300) == nil, "too early at 200 ms")
    // Moving again restarts the wait.
    state.recordMovement(to: CGPoint(x: 20, y: 10), at: 1.25)
    expect(state.nextEvaluation(at: 1.4, delayMilliseconds: 300) == nil, "restarted wait not yet over")
    guard let evaluation = state.nextEvaluation(at: 1.56, delayMilliseconds: 300) else {
        expect(false, "evaluation due after 310 ms at rest")
        return
    }
    expect(evaluation.point == CGPoint(x: 20, y: 10), "evaluation uses the resting point")
    expect(state.isCurrent(evaluation), "fresh evaluation is current")
    expect(state.nextEvaluation(at: 2, delayMilliseconds: 300) == nil, "no second evaluation while one runs")

    state.finishEvaluation(evaluation)
    expect(!state.hasPendingEvaluation, "finished: nothing pending")
    expect(state.nextEvaluation(at: 5, delayMilliseconds: 300) == nil, "resting pointer never re-raises")

    // Movement during an evaluation makes it stale.
    state.recordMovement(to: CGPoint(x: 30, y: 30), at: 6)
    let second = state.nextEvaluation(at: 6.4, delayMilliseconds: 300)
    expect(second != nil, "evaluation after new movement")
    state.recordMovement(to: CGPoint(x: 31, y: 30), at: 6.41)
    if let second { expect(!state.isCurrent(second), "movement makes a running evaluation stale") }

    state.reset()
    expect(!state.hasPendingEvaluation, "reset clears the pointer")

    // The delay itself is clamped: 10 ms behaves as 100 ms.
    var fast = HoverDwellState()
    fast.recordMovement(to: .zero, at: 0)
    expect(fast.nextEvaluation(at: 0.05, delayMilliseconds: 10) == nil, "clamped minimum delay applies")
    expect(fast.nextEvaluation(at: 0.11, delayMilliseconds: 10) != nil, "fires after clamped 100 ms")
}

// MARK: - Window scan and gate

private func entry(_ id: UInt32, pid: Int32, layer: Int, rect: CGRect, alpha: Double = 1) -> [String: Any] {
    [
        kCGWindowNumber as String: NSNumber(value: id),
        kCGWindowOwnerPID as String: NSNumber(value: pid),
        kCGWindowLayer as String: NSNumber(value: layer),
        kCGWindowAlpha as String: NSNumber(value: alpha),
        kCGWindowBounds as String: rect.dictionaryRepresentation
    ]
}

private func testScan() {
    let raw = [
        entry(9, pid: 50, layer: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50), alpha: 0),
        entry(1, pid: 10, layer: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
        entry(2, pid: 20, layer: 0, rect: CGRect(x: 50, y: 50, width: 200, height: 200)),
        [kCGWindowNumber as String: NSNumber(value: 3)]
    ]
    let windows = raw.compactMap(HoverWindowScan.info(from:))
    expect(windows.count == 2, "transparent and incomplete entries are dropped")
    expect(HoverWindowScan.target(in: windows, at: CGPoint(x: 60, y: 60), pointerWindowID: nil)?.windowID == 1,
           "frontmost containing window wins without a pointer window")
    expect(HoverWindowScan.target(in: windows, at: CGPoint(x: 60, y: 60), pointerWindowID: 2)?.windowID == 2,
           "AppKit's receiving window wins when given")
    expect(HoverWindowScan.target(in: windows, at: CGPoint(x: 5, y: 5), pointerWindowID: 2) == nil,
           "pointer window must contain the point")
    expect(HoverWindowScan.target(in: windows, at: CGPoint(x: 500, y: 500), pointerWindowID: nil) == nil,
           "empty desktop has no target")

    let cursor = HoverWindowInfo(windowID: 2, ownerPID: 99, layer: HoverWindowScan.cursorLayer,
                                 bounds: CGRect(x: 55, y: 55, width: 20, height: 20))
    expect(HoverWindowScan.target(in: [cursor] + windows, at: CGPoint(x: 60, y: 60), pointerWindowID: nil)?.windowID == 1,
           "the pointer's own window is looked through")

    let menu = HoverWindowInfo(windowID: 7, ownerPID: 30, layer: HoverWindowScan.popUpMenuLayer, bounds: .zero)
    expect(HoverWindowScan.isMenuOpen(in: windows + [menu]), "a pop-up menu layer window means a menu is open")
    expect(!HoverWindowScan.isMenuOpen(in: windows), "no menu window, no menu")
}

private func testGate() {
    let window = HoverWindowInfo(windowID: 42, ownerPID: 100, layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
    var input = HoverFocusInput()
    input.target = window
    input.targetBundleID = "com.example.editor"
    input.ownPID = 1
    input.frontmostPID = 200

    expect(HoverFocusGate.decide(input) == .raise(windowID: 42, pid: 100), "plain case raises")

    var copy = input; copy.menuOpen = true
    expect(HoverFocusGate.decide(copy) == .skip(.menuOpen), "never while a menu is open")
    copy = input; copy.mouseButtonsDown = true
    expect(HoverFocusGate.decide(copy) == .skip(.buttonOrModifierHeld), "never while dragging")
    copy = input; copy.modifiersHeld = true
    expect(HoverFocusGate.decide(copy) == .skip(.buttonOrModifierHeld), "never while a modifier is held")
    copy = input; copy.displayEnabled = false
    expect(HoverFocusGate.decide(copy) == .skip(.displayNotEnabled), "only on opted-in displays")
    copy = input; copy.target = nil
    expect(HoverFocusGate.decide(copy) == .skip(.noWindow), "nothing under the pointer")
    copy = input; copy.ownPID = 100
    expect(HoverFocusGate.decide(copy) == .skip(.wharfWindow), "never Wharf's own windows")
    copy = input; copy.targetBundleID = "com.apple.dock"
    expect(HoverFocusGate.decide(copy) == .skip(.dock), "never the Dock")
    copy = input; copy.target = HoverWindowInfo(windowID: 42, ownerPID: 100, layer: 20, bounds: window.bounds)
    expect(HoverFocusGate.decide(copy) == .skip(.notAnAppWindow), "only ordinary app windows")
    copy = input; copy.excludedBundleIDs = ["com.example.editor"]
    expect(HoverFocusGate.decide(copy) == .skip(.excludedApp), "excluded apps are left alone")

    copy = input; copy.frontmostPID = 100; copy.focusedWindowID = 42
    expect(HoverFocusGate.decide(copy) == .skip(.alreadyFocused), "already focused window is not raised again")
    copy = input; copy.frontmostPID = 100; copy.focusedWindowID = nil
    expect(HoverFocusGate.decide(copy) == .skip(.alreadyFocused), "unknown focus in the front app is left alone")
    copy = input; copy.frontmostPID = 100; copy.focusedWindowID = 43
    expect(HoverFocusGate.decide(copy) == .raise(windowID: 42, pid: 100), "another window of the front app is raised")
}

// MARK: - Spaces order

private func testSpacesSetting() {
    expect(SpacesRearrangeSetting.from(raw: nil, isForced: false) == .absent, "missing key")
    expect(SpacesRearrangeSetting.from(raw: NSNumber(value: true), isForced: false) == .on, "true")
    expect(SpacesRearrangeSetting.from(raw: NSNumber(value: false), isForced: false) == .off, "false")
    expect(SpacesRearrangeSetting.from(raw: "yes", isForced: false) == .unsupported, "non boolean")
    expect(SpacesRearrangeSetting.from(raw: NSNumber(value: true), isForced: true) == .unsupported, "managed")
}

private func testSpacesSteps() {
    typealias P = SpacesOrderPlan
    func held(_ restore: String) -> SpacesOrderJournal { SpacesOrderJournal(restore: restore, phase: .held) }
    // Turning on.
    expect(P.step(wanted: true, current: .absent, journal: nil) == .hold(restore: P.restoreAbsent), "absent: hold, remember absent")
    expect(P.step(wanted: true, current: .on, journal: nil) == .hold(restore: P.restoreOn), "on: hold, remember on")
    expect(P.step(wanted: true, current: .off, journal: nil) == .remember, "already off: remember only")
    expect(P.step(wanted: true, current: .unsupported, journal: nil) == .none, "managed: never write")
    // Steady state.
    expect(P.step(wanted: true, current: .off, journal: held(P.restoreOn)) == .none, "held: nothing to do")
    // The user turned it back on in System Settings.
    expect(P.step(wanted: true, current: .on, journal: held(P.restoreOn)) == .letGo, "user took it back: let go")
    expect(P.step(wanted: true, current: .absent, journal: held(P.restoreOn)) == .letGo, "user reset it: let go")
    // Turning off.
    expect(P.step(wanted: false, current: .off, journal: held(P.restoreOn)) == .release(removeKey: false), "restore true")
    expect(P.step(wanted: false, current: .off, journal: held(P.restoreAbsent)) == .release(removeKey: true), "restore missing key")
    expect(P.step(wanted: false, current: .off, journal: held(P.restoreOff)) == .forget, "was already off: leave it")
    expect(P.step(wanted: false, current: .on, journal: held(P.restoreOn)) == .forget, "user changed it: leave it")
    expect(P.step(wanted: false, current: .absent, journal: nil) == .none, "never held: nothing")
    expect(P.step(wanted: false, current: .off, journal: held(P.restoreOn)) != .none, "a held journal is never ignored")
    // Managed after the fact: drop the record, never write.
    expect(P.step(wanted: true, current: .unsupported, journal: held(P.restoreOn)) == .forget, "managed later: forget")
    expect(P.step(wanted: false, current: .unsupported, journal: held(P.restoreOn)) == .forget, "managed later, off: forget")
}

/// The recovery journal phases: what the next launch does after Wharf was
/// cut off at each point of a change.
private func testSpacesJournalPhases() {
    typealias P = SpacesOrderPlan
    func j(_ restore: String, _ phase: SpacesHoldPhase) -> SpacesOrderJournal { SpacesOrderJournal(restore: restore, phase: phase) }

    // Journal saved, Dock write never happened. This used to read as "the
    // user took it back" and turned the feature off.
    expect(P.step(wanted: true, current: .on, journal: j(P.restoreOn, .pendingHold)) == .hold(restore: P.restoreOn),
           "pending hold, Dock untouched: retry with the saved value, not let go")
    expect(P.step(wanted: true, current: .absent, journal: j(P.restoreAbsent, .pendingHold)) == .hold(restore: P.restoreAbsent),
           "pending hold from a missing key: retry, still remembers absent")
    // Dock write landed, the held mark did not.
    expect(P.step(wanted: true, current: .off, journal: j(P.restoreOn, .pendingHold)) == .confirmHold,
           "pending hold, Dock already off: confirm")
    // Feature switched off before a pending hold finished.
    expect(P.step(wanted: false, current: .off, journal: j(P.restoreAbsent, .pendingHold)) == .release(removeKey: true),
           "pending hold that may have landed: put the old value back")
    expect(P.step(wanted: false, current: .on, journal: j(P.restoreOn, .pendingHold)) == .forget,
           "pending hold that never landed: just forget")
    // Release interrupted.
    expect(P.step(wanted: false, current: .off, journal: j(P.restoreOn, .pendingRelease)) == .release(removeKey: false),
           "pending release, Dock still off: retry the release")
    expect(P.step(wanted: false, current: .on, journal: j(P.restoreOn, .pendingRelease)) == .forget,
           "pending release that landed: clear the journal")
    expect(P.step(wanted: false, current: .absent, journal: j(P.restoreAbsent, .pendingRelease)) == .forget,
           "pending release of a missing key that landed: clear")
    // Switched back on while a release was unfinished.
    expect(P.step(wanted: true, current: .off, journal: j(P.restoreOn, .pendingRelease)) == .confirmHold,
           "back on before release landed: keep holding")
    expect(P.step(wanted: true, current: .on, journal: j(P.restoreOn, .pendingRelease)) == .hold(restore: P.restoreOn),
           "back on after release landed: hold again")
}

private func testBundleIDList() {
    typealias L = BundleIDList
    expect(L.normalized("  COM.Apple.Terminal \n") == "com.apple.terminal", "trim and lowercase")
    expect(L.matchSet(["com.apple.Terminal", "COM.APPLE.TERMINAL", " "]) == ["com.apple.terminal"], "match set dedupes, drops blanks")
    expect(L.contains(["com.apple.Terminal"], "com.apple.terminal"), "contains ignores case")
    expect(L.adding("COM.APPLE.SAFARI", to: ["com.apple.Safari"]) == ["com.apple.Safari"], "case variant is a duplicate")
    expect(L.adding("  com.example.App ", to: []) == ["com.example.App"], "added trimmed, spelling kept")
    expect(L.adding("   ", to: ["a"]) == ["a"], "blank not added")
    expect(L.deduplicated(["com.A", "COM.a", "com.b", ""]) == ["com.A", "com.b"], "dedupe keeps first spelling")

    // The hover gate matches exclusions without regard to case.
    let window = HoverWindowInfo(windowID: 9, ownerPID: 50, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    var input = HoverFocusInput()
    input.ownPID = 1
    input.target = window
    input.targetBundleID = "com.Example.App"
    input.excludedBundleIDs = L.matchSet(["COM.EXAMPLE.APP"])
    expect(HoverFocusGate.decide(input) == .skip(.excludedApp), "case variant exclusion applies")
    input.targetBundleID = "com.apple.Dock"
    input.excludedBundleIDs = []
    expect(HoverFocusGate.decide(input) == .skip(.dock), "Dock recognized in any case")
}

private func testStoredDelay() {
    typealias T = FocusFollowsMouseTiming
    expect(T.storedDelay(nil) == (300, false), "missing: default, nothing to write")
    expect(T.storedDelay(450) == (450, false), "in range: kept")
    expect(T.storedDelay(5_000) == (2_000, true), "too long: clamped and written back")
    expect(T.storedDelay(-1) == (100, true), "negative: clamped and written back")
    expect(T.storedDelay("fast") == (300, true), "malformed: default and written back")
}

private func testHoverCommitCheck() {
    let point = CGPoint(x: 100, y: 100)
    let ok = HoverCommitCheck(livePointer: point, receivingWindowID: 7)
    expect(ok.allowsRaise(of: 7, restingAt: point), "all clear: raise")
    var check = ok
    check.livePointer = CGPoint(x: 400, y: 100)
    expect(!check.allowsRaise(of: 7, restingAt: point), "pointer moved away (into Wharf, say): no raise")
    check = ok
    check.livePointer = nil
    expect(!check.allowsRaise(of: 7, restingAt: point), "pointer unknown: no raise")
    check = ok
    check.receivingWindowID = 8
    expect(!check.allowsRaise(of: 7, restingAt: point), "another window now under the pointer: no raise")
    check = ok
    check.menuOpen = true
    expect(!check.allowsRaise(of: 7, restingAt: point), "menu opened meanwhile: no raise")
    check = ok
    check.buttonOrModifierHeld = true
    expect(!check.allowsRaise(of: 7, restingAt: point), "click or shortcut started: no raise")
    check = ok
    check.featureActive = false
    expect(!check.allowsRaise(of: 7, restingAt: point), "switched off meanwhile: no raise")
    check = ok
    check.evaluationCurrent = false
    expect(!check.allowsRaise(of: 7, restingAt: point), "stale evaluation: no raise")
    check = ok
    check.livePointer = CGPoint(x: 102, y: 99)
    expect(check.allowsRaise(of: 7, restingAt: point), "a point or two of jitter is fine")
}

// MARK: - Win key tap

private func testCommandTap() {
    typealias D = CommandTapDetector
    var d = D()
    expect(!d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0)), "press alone does not fire")
    expect(d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.1)), "lone tap fires on release")

    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.keyDown)
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.2)), "Cmd+key is not a tap")

    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.mouseDown)
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.2)), "Cmd+click is not a tap")

    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: true, time: 0.1))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0.15))
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.2)), "Cmd+Shift is not a tap")

    d = D()
    _ = d.handle(.flagsChanged(command: false, otherModifiers: true, time: 0))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: true, time: 0.05))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0.1))
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.2)), "Shift then Cmd is not a tap")

    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 2)), "a long hold is not a tap")

    // A key pressed before Command does not spoil the next tap.
    d = D()
    _ = d.handle(.keyDown)
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 5))
    expect(d.handle(.flagsChanged(command: false, otherModifiers: false, time: 5.1)), "earlier keys do not matter")

    // A release with no press seen (tap installed mid-hold) never fires.
    d = D()
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 1)), "release without press")

    // Two taps in a row both fire.
    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.1))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0.3))
    expect(d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.4)), "second tap fires too")

    // Command+Q and other chords never count.
    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.keyDown)
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.1)), "Cmd+Q is not a tap")

    // Command with the scroll wheel (zoom) is not a tap.
    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    _ = d.handle(.scrollWheel)
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.3)), "Cmd+scroll is not a tap")

    // Mouse held first, then Command pressed and released: changing a drag.
    d = D()
    _ = d.handle(.mouseDown)
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 1, mouseHeld: true))
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 1.2, mouseHeld: true)),
           "mouse down, Cmd down, Cmd up with the button held is not a tap")

    // Button pressed and released by mouse up between Command down and up.
    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0))
    expect(!d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.2, mouseHeld: true)),
           "button held at Cmd release is not a tap")

    // After the drag ends, a clean tap still works.
    d = D()
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 0, mouseHeld: true))
    _ = d.handle(.flagsChanged(command: false, otherModifiers: false, time: 0.1, mouseHeld: true))
    _ = d.handle(.flagsChanged(command: true, otherModifiers: false, time: 2))
    expect(d.handle(.flagsChanged(command: false, otherModifiers: false, time: 2.1)), "tap after a drag fires")
}

private func testWinKeyActions() {
    expect(WinKeyTapAction(rawValue: "startMenu") == .startMenu, "raw value round trip")
    expect(WinKeyTapAction.allCases.count == 3, "three choices")
}

@main
enum FocusAndWinTapTests {
    static func main() {
        testDelayClamp()
        testDwell()
        testScan()
        testGate()
        testSpacesSetting()
        testSpacesSteps()
        testSpacesJournalPhases()
        testBundleIDList()
        testStoredDelay()
        testHoverCommitCheck()
        testCommandTap()
        testWinKeyActions()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
