//
//  WindowBehaviorLogicTests.swift
//  Standalone checks for WindowBehaviorLogic.swift. Built and run by
//  scripts/test-window-behavior.sh; not part of the app target.
//

import CoreGraphics
import Foundation

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL line \(line): \(message)")
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

@main
struct WindowBehaviorLogicTests {
    static func main() {
        // MARK: Bundle lists

        expect(WindowBehaviorBundleList.sanitized([" com.a ", "", "com.A", "com.b", "  "]), ["com.a", "com.b"], "sanitize trims, dedupes case-insensitively")
        check(WindowBehaviorBundleList.contains("com.apple.Safari", in: ["com.apple.safari"]), "match ignores case")
        check(!WindowBehaviorBundleList.contains("com.apple.Safari", in: ["com.apple.Saf"]), "no prefix match")
        check(!WindowBehaviorBundleList.contains(nil, in: ["com.a"]), "nil bundle id never listed")
        check(!WindowBehaviorBundleList.contains("", in: [""]), "empty bundle id never listed")
        check(WindowBehaviorBundleList.contains("com.a", in: [" com.a "]), "stored whitespace tolerated")

        // MARK: Traffic light scan

        func windowInfo(pid: Int32, number: UInt32, rect: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
            [
                kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowAlpha as String: NSNumber(value: alpha),
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowNumber as String: NSNumber(value: number)
            ]
        }

        let front = windowInfo(pid: 10, number: 1, rect: CGRect(x: 100, y: 100, width: 800, height: 600))
        let behind = windowInfo(pid: 20, number: 2, rect: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let zoomPoint = CGPoint(x: 100 + 60, y: 100 + 14)

        expect(TrafficLightHitTest.candidate(in: [front, behind], at: zoomPoint, button: .zoom, ownProcessID: 99)?.windowID, 1, "zoom hit on front window")
        expect(TrafficLightHitTest.candidate(in: [front, behind], at: CGPoint(x: 400, y: 400), button: .zoom, ownProcessID: 99), nil, "click inside window body is no candidate")
        expect(TrafficLightHitTest.candidate(in: [front, behind], at: CGPoint(x: 100 + 14, y: 114), button: .zoom, ownProcessID: 99), nil, "close button area is not zoom")
        expect(TrafficLightHitTest.candidate(in: [front, behind], at: CGPoint(x: 100 + 14, y: 114), button: .close, ownProcessID: 99)?.pid, 10, "close area found for close")
        expect(TrafficLightHitTest.candidate(in: [front, behind], at: zoomPoint, button: .zoom, ownProcessID: 10), nil, "own window skipped, and the window behind does not contain the zoom area at that point")
        expect(TrafficLightHitTest.candidate(in: [front, behind], at: zoomPoint, button: .zoom, ownProcessID: 99, pidIsEligible: { $0 != 10 }), nil, "ineligible front window ends the scan instead of falling through")
        let menuLayer = windowInfo(pid: 30, number: 3, rect: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 25)
        expect(TrafficLightHitTest.candidate(in: [menuLayer, front], at: zoomPoint, button: .zoom, ownProcessID: 99)?.windowID, 1, "non-normal layer skipped")
        let invisible = windowInfo(pid: 31, number: 4, rect: CGRect(x: 100, y: 100, width: 800, height: 600), alpha: 0)
        expect(TrafficLightHitTest.candidate(in: [invisible, front], at: zoomPoint, button: .zoom, ownProcessID: 99)?.windowID, 1, "transparent window skipped")
        let tiny = windowInfo(pid: 32, number: 5, rect: CGRect(x: 150, y: 100, width: 40, height: 40))
        expect(TrafficLightHitTest.candidate(in: [tiny, front], at: zoomPoint, button: .zoom, ownProcessID: 99)?.windowID, 1, "tiny window skipped")
        check(TrafficLightHitTest.contains(CGPoint(x: 42, y: 0), inTrafficLightAreaOf: CGRect(x: 0, y: 0, width: 500, height: 500), button: .zoom), "zoom area left edge")
        check(!TrafficLightHitTest.contains(CGPoint(x: 105, y: 0), inTrafficLightAreaOf: CGRect(x: 0, y: 0, width: 500, height: 500), button: .zoom), "zoom area right edge")
        check(!TrafficLightHitTest.contains(CGPoint(x: 60, y: 47), inTrafficLightAreaOf: CGRect(x: 0, y: 0, width: 500, height: 500), button: .zoom), "below title bar")

        // MARK: Green button decisions

        expect(GreenButtonLogic.action(command: false, control: false, option: false, shift: false), .toggleMaximize, "plain click maximizes")
        expect(GreenButtonLogic.action(command: false, control: false, option: true, shift: false), .nativeFullScreen, "option gives full screen")
        expect(GreenButtonLogic.action(command: true, control: false, option: false, shift: false), .passThrough, "command passes")
        expect(GreenButtonLogic.action(command: false, control: false, option: true, shift: true), .passThrough, "option plus shift passes")
        expect(GreenButtonLogic.action(command: false, control: true, option: false, shift: false), .passThrough, "control passes")
        let target = CGRect(x: 0, y: 25, width: 1440, height: 800)
        check(GreenButtonLogic.isMaximized(CGRect(x: 2, y: 27, width: 1437, height: 803), target: target), "within tolerance is maximized")
        check(!GreenButtonLogic.isMaximized(CGRect(x: 0, y: 25, width: 1400, height: 800), target: target), "narrower is not maximized")

        // MARK: Quit on close

        let quittable = QuitOnCloseFacts(isListed: true, isRegular: true, isOwnProcess: false, isTerminated: false,
                                         isHidden: false, hadWindow: true, accessibilityWindowCount: 0, serverWindowCount: 0)
        check(QuitOnCloseLogic.shouldQuit(quittable), "listed app with no windows left quits")
        var facts = quittable; facts.isListed = false
        check(!QuitOnCloseLogic.shouldQuit(facts), "unlisted app stays")
        facts = quittable; facts.isRegular = false
        check(!QuitOnCloseLogic.shouldQuit(facts), "menu bar app stays")
        facts = quittable; facts.hadWindow = false
        check(!QuitOnCloseLogic.shouldQuit(facts), "app that never showed a window stays")
        facts = quittable; facts.isHidden = true
        check(!QuitOnCloseLogic.shouldQuit(facts), "hidden app stays")
        facts = quittable; facts.accessibilityWindowCount = 1
        check(!QuitOnCloseLogic.shouldQuit(facts), "minimized or remaining window keeps it")
        facts = quittable; facts.serverWindowCount = 1
        check(!QuitOnCloseLogic.shouldQuit(facts), "window on another Space keeps it")
        facts = quittable; facts.isOwnProcess = true
        check(!QuitOnCloseLogic.shouldQuit(facts), "Wharf never quits itself")
        facts = quittable; facts.isTerminated = true
        check(!QuitOnCloseLogic.shouldQuit(facts), "already terminated")
        let serverList = [
            windowInfo(pid: 7, number: 1, rect: CGRect(x: 0, y: 0, width: 600, height: 400)),
            windowInfo(pid: 7, number: 2, rect: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 3),
            windowInfo(pid: 7, number: 3, rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
            windowInfo(pid: 8, number: 4, rect: CGRect(x: 0, y: 0, width: 600, height: 400))
        ]
        expect(QuitOnCloseLogic.serverWindowCount(in: serverList, pid: 7), 2, "normal and panel level, sizeable windows of the pid count")
        let dialogList = [
            windowInfo(pid: 7, number: 5, rect: CGRect(x: 0, y: 0, width: 400, height: 200), layer: 8),
            windowInfo(pid: 7, number: 6, rect: CGRect(x: 0, y: 0, width: 400, height: 200), layer: 25)
        ]
        expect(QuitOnCloseLogic.serverWindowCount(in: dialogList, pid: 7), 1, "a modal panel counts, a status item level window does not")
        expect(QuitOnCloseLogic.serverWindowCount(in: nil, pid: 7), nil, "an unreadable list is unknown, never zero")
        check(QuitOnCloseLogic.checkDelays.first! >= 0.3, "first look waits out the close fade")
        facts = quittable; facts.accessibilityWindowCount = nil
        check(!QuitOnCloseLogic.shouldQuit(facts), "a failed Accessibility read keeps the app")
        facts = quittable; facts.serverWindowCount = nil
        check(!QuitOnCloseLogic.shouldQuit(facts), "a failed window server read keeps the app")
        facts = quittable; facts.quitAlreadyRequested = true
        check(!QuitOnCloseLogic.shouldQuit(facts), "no second quit request in the same windowless stretch")

        // Episode record: one quit per windowless stretch.
        var episodes = QuitOnCloseEpisodes()
        episodes.requestedQuit(7)
        check(episodes.hasRequestedQuit(7), "quit request recorded")
        episodes.sawWindow(of: 7, isStandard: false)
        check(episodes.hasRequestedQuit(7), "a dialog (save prompt) does not end the stretch")
        episodes.sawWindow(of: 7, isStandard: true)
        check(!episodes.hasRequestedQuit(7), "a real window ends the stretch")
        episodes.requestedQuit(8)
        check(!episodes.hasRequestedQuit(7), "records are per app")
        episodes.forget(8)
        check(!episodes.hasRequestedQuit(8), "a quit app is forgotten")

        // Right-to-left layouts mirror the traffic lights.
        let rtlBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        check(TrafficLightHitTest.contains(CGPoint(x: 500 - 60, y: 14), inTrafficLightAreaOf: rtlBounds, button: .zoom, rightToLeft: true), "zoom area at the top right in RTL")
        check(!TrafficLightHitTest.contains(CGPoint(x: 60, y: 14), inTrafficLightAreaOf: rtlBounds, button: .zoom, rightToLeft: true), "top left is not the zoom area in RTL")
        expect(TrafficLightHitTest.candidate(in: [front], at: CGPoint(x: 900 - 60, y: 114), button: .zoom, ownProcessID: 99, rightToLeft: true)?.windowID, 1, "RTL candidate found at the trailing edge")

        // MARK: Quit guard policy

        let policy = QuitGuardPolicy(defaultMode: .hold, overrides: ["com.apple.Terminal": .doublePress, "com.x": .off],
                                     protectsQuit: true, protectsClose: false)
        expect(policy.mode(for: "com.apple.terminal", key: .quit), .doublePress, "override wins, case-insensitive")
        expect(policy.mode(for: "com.x", key: .quit), .off, "override can turn it off")
        expect(policy.mode(for: "com.other", key: .quit), .hold, "default otherwise")
        expect(policy.mode(for: nil, key: .quit), .hold, "no bundle id uses default")
        expect(policy.mode(for: "com.apple.Terminal", key: .close), .off, "unprotected key is off")
        expect(policy.mode(for: "com.microsoft.rdc.macos", key: .quit), .off, "remote desktop passes keys through by default")
        expect(policy.mode(for: "com.vmware.fusion", key: .quit), .off, "VMs pass keys through by default")
        let vmOverride = QuitGuardPolicy(defaultMode: .hold, overrides: ["com.utmapp.UTM": .doublePress], protectsQuit: true, protectsClose: true)
        expect(vmOverride.mode(for: "com.utmapp.utm", key: .quit), .doublePress, "an explicit override still wins for a VM")

        expect(QuitGuardKey.matching(character: "Q", keyCode: 0), .quit, "character match")
        expect(QuitGuardKey.matching(character: "w", keyCode: 0), .close, "close character")
        expect(QuitGuardKey.matching(character: "й", keyCode: 12), nil, "a readable other character wins over the key position")
        expect(QuitGuardKey.matching(character: nil, keyCode: 13), .close, "fallback key code")
        expect(QuitGuardKey.matching(character: "a", keyCode: 0), nil, "other key")

        // MARK: Quit guard state machine

        let cmd = QuitGuardModifiers(command: true)
        let cmdShift = QuitGuardModifiers(command: true, shift: true)
        let none = QuitGuardModifiers()
        let ms: UInt64 = 1_000_000
        typealias D = QuitGuardStateMachine.Decision

        // Hold: release early cancels, holding confirms, the release after is swallowed.
        var machine = QuitGuardStateMachine()
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5), D.beginHold(.quit), "hold begins")
        let firstSequence = machine.pending!.sequence
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: true, timestamp: 50 * ms, mode: .hold, target: 5), D.swallow, "repeat swallowed while holding")
        expect(machine.keyUp(keyCode: 12), D.cancel, "early release cancels")
        expect(machine.holdElapsed(sequence: firstSequence), D.pass, "stale timer does nothing after cancel")
        check(!machine.hasPressInFlight, "nothing in flight after cancel")

        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        let holdSequence = machine.pending!.sequence
        expect(machine.holdElapsed(sequence: holdSequence - 1), D.pass, "older timer ignored")
        expect(machine.holdElapsed(sequence: holdSequence), D.confirm(.quit, target: 5), "hold confirms for the captured app")
        expect(machine.confirmedSequence, holdSequence, "confirm names the sequence it finished")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: true, timestamp: 900 * ms, mode: .hold, target: 6), D.swallow, "repeat after confirm swallowed")
        expect(machine.keyUp(keyCode: 12), D.swallow, "release after confirm swallowed")
        expect(machine.keyUp(keyCode: 12), D.pass, "a second release passes")

        // Hold: command released cancels, but the still-held key stays owned.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        expect(machine.commandChanged(isHeld: false), D.cancel, "letting go of Command cancels")
        expect(machine.commandChanged(isHeld: false), D.pass, "nothing more to cancel")
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: none, isRepeat: true, timestamp: 100 * ms, mode: .hold, target: 5), D.swallow, "autorepeat of the held W after the cancel is swallowed, not typed")
        expect(machine.keyUp(keyCode: 13), D.swallow, "its release is swallowed too")
        expect(machine.keyUp(keyCode: 13), D.pass, "and only once")

        // Physical key ownership: the release matches by key code even when
        // the character it types changed (input source switched mid hold).
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        expect(machine.keyUp(keyCode: 12), D.cancel, "release found by key code alone")
        check(machine.pending == nil, "and the hold is over, so no timer can quit after the release")

        // A fresh press of an owned key (its release was missed) is judged anew.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        _ = machine.commandChanged(isHeld: false)
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: none, isRepeat: false, timestamp: 500 * ms, mode: .hold, target: 5), D.pass, "fresh plain q after a missed release types normally")
        expect(machine.keyUp(keyCode: 12), D.pass, "and its release passes with it")

        // Escape cancels and owns its own release.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        expect(machine.keyDown(key: nil, keyCode: 53, modifiers: cmd, isRepeat: false, timestamp: 10 * ms, mode: .hold, target: 5), D.cancel, "escape cancels")
        expect(machine.keyDown(key: nil, keyCode: 53, modifiers: cmd, isRepeat: true, timestamp: 60 * ms, mode: .hold, target: 5), D.swallow, "escape repeat swallowed")
        expect(machine.keyUp(keyCode: 53), D.swallow, "escape release swallowed, no unmatched key-up")
        expect(machine.keyUp(keyCode: 13), D.swallow, "the W release still swallowed after the cancel")
        check(!machine.hasPressInFlight, "everything released")

        // Hold: extra modifiers are not the protected shortcut.
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdShift, isRepeat: false, timestamp: 0, mode: .hold, target: 5), D.pass, "Command-Shift-Q passes in hold mode")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: none, isRepeat: false, timestamp: 0, mode: .hold, target: 5), D.pass, "plain q typing passes")
        expect(machine.keyDown(key: nil, keyCode: 0, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5), D.pass, "Command-A passes")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .off, target: 5), D.pass, "off passes")
        check(!machine.hasPressInFlight, "passed keys are never owned")

        // Double press, same app.
        machine = QuitGuardStateMachine()
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5), D.beginDoublePress(.quit), "first press waits")
        expect(machine.keyUp(keyCode: 12), D.swallow, "first release swallowed, still waiting")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 400 * ms, mode: .doublePress, target: 5), D.confirm(.quit, target: 5), "second press in time in the same app confirms")
        expect(machine.keyUp(keyCode: 12), D.swallow, "second release swallowed")

        // Double press target binding: a second press in another app never
        // confirms the first app; it starts that app's own sequence.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.keyUp(keyCode: 12)
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 400 * ms, mode: .doublePress, target: 9), D.beginDoublePress(.quit), "press in another app starts over")
        expect(machine.pending?.target, 9, "and belongs to the new app")

        // Switching apps ends a wait that belongs to another app.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        expect(machine.frontmostChanged(to: 5), D.pass, "same app in front keeps the wait")
        expect(machine.frontmostChanged(to: 9), D.cancel, "another app in front cancels")
        check(machine.pending == nil, "nothing pending after the switch")
        expect(machine.keyUp(keyCode: 12), D.swallow, "the held key stays owned across the switch")
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        let switchSequence = machine.pending!.sequence
        _ = machine.frontmostChanged(to: 9)
        expect(machine.holdElapsed(sequence: switchSequence), D.pass, "a hold timer after an app switch quits nothing")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.keyUp(keyCode: 12)
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 700 * ms, mode: .doublePress, target: 5), D.beginDoublePress(.quit), "too slow starts over")
        let doubleSequence = machine.pending!.sequence
        expect(machine.expired(sequence: doubleSequence), D.cancel, "expiry cancels")
        expect(machine.expired(sequence: doubleSequence), D.pass, "expiry only once")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: true, timestamp: 900 * ms, mode: .doublePress, target: 5), D.swallow, "repeat after the expiry still swallowed")
        expect(machine.keyUp(keyCode: 12), D.swallow, "release after the expiry swallowed")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.keyUp(keyCode: 12)
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 100 * ms, mode: .off, target: 5), D.pass, "a different unprotected shortcut passes")
        check(machine.pending == nil, "and ends the wait")

        machine = QuitGuardStateMachine()
        machine.doublePressMilliseconds = 300
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.keyUp(keyCode: 13)
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 350 * ms, mode: .doublePress, target: 5), D.beginDoublePress(.close), "custom interval respected")

        // Extra modifier.
        machine = QuitGuardStateMachine()
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .extraModifier, target: 5), D.showModifierHint(.quit, .shift), "bare shortcut shows the hint")
        expect(machine.keyUp(keyCode: 12), D.swallow, "hint stays after release")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdShift, isRepeat: false, timestamp: 200 * ms, mode: .extraModifier, target: 6), D.confirm(.quit, target: 6), "with Shift confirms for the app the press went to")
        expect(machine.confirmedSequence, nil, "a one-press confirm has no earlier sequence")
        expect(machine.keyUp(keyCode: 12), D.swallow, "its release swallowed")
        machine.extraModifier = .option
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmdShift, isRepeat: false, timestamp: 0, mode: .extraModifier, target: 5), D.pass, "wrong extra modifier passes untouched")
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: QuitGuardModifiers(command: true, option: true), isRepeat: false, timestamp: 0, mode: .extraModifier, target: 5), D.confirm(.close, target: 5), "chosen modifier confirms")

        // Interval helper and clamps.
        check(QuitGuardStateMachine.isWithin(first: 0, second: 600 * ms, milliseconds: 600), "edge of interval counts")
        check(!QuitGuardStateMachine.isWithin(first: 10, second: 5, milliseconds: 600), "time going backward never counts")
        expect(QuitGuardStateMachine.clampedHold(5_000), 2_000, "hold clamps high")
        expect(QuitGuardStateMachine.clampedHold(.nan), 800, "hold NaN falls back")
        expect(QuitGuardStateMachine.clampedDoublePress(10), 200, "double press clamps low")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        machine.reset()
        check(!machine.hasPressInFlight, "reset clears everything")

        // MARK: Green button pairs

        typealias G = GreenButtonPairTracker.Decision
        var pair = GreenButtonPairTracker()
        let token = pair.pressSwallowed()
        expect(pair.dragged(), G.swallow, "drags of a held press are swallowed")
        expect(pair.released(insideButton: true), G.perform(token: token), "release on the button performs")
        expect(pair.released(insideButton: true), G.pass, "a second release passes")

        pair = GreenButtonPairTracker()
        _ = pair.pressSwallowed()
        expect(pair.released(insideButton: false), G.swallow, "release away cancels but stays paired")

        pair = GreenButtonPairTracker()
        let holdToken = pair.pressSwallowed()
        expect(pair.holdElapsed(token: holdToken - 1), G.pass, "an old hold timer does nothing")
        expect(pair.holdElapsed(token: holdToken), G.replayPress, "a held press is handed back to the app")
        expect(pair.dragged(), G.pass, "drags then reach the app")
        expect(pair.released(insideButton: true), G.pass, "and so does the release, after its press")

        pair = GreenButtonPairTracker()
        let staleToken = pair.pressSwallowed()
        pair.interrupted()
        expect(pair.released(insideButton: true), G.pass, "after an interruption the release passes and nothing is performed")
        expect(pair.holdElapsed(token: staleToken), G.pass, "and no stale press is replayed")

        pair = GreenButtonPairTracker()
        _ = pair.pressSwallowed()
        pair.pressPassed()
        expect(pair.released(insideButton: true), G.pass, "a press Wharf passed keeps its release")

        if failed == 0 {
            print("PASS: \(passed) checks")
            exit(0)
        } else {
            print("FAILED: \(failed) of \(passed + failed) checks")
            exit(1)
        }
    }
}
