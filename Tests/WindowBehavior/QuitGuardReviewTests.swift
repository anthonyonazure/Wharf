//
//  QuitGuardReviewTests.swift
//  Standalone checks for the quit protection and quit on close fixes from
//  the chunk 1 code review. Built and run by scripts/test-window-behavior.sh
//  as its own program; not part of the app target.
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
struct QuitGuardReviewTests {
    static func main() {
        typealias D = QuitGuardStateMachine.Decision
        let ms: UInt64 = 1_000_000
        let cmd = QuitGuardModifiers(command: true)
        let cmdShift = QuitGuardModifiers(command: true, shift: true)
        let cmdControl = QuitGuardModifiers(command: true, control: true)
        let cmdOption = QuitGuardModifiers(command: true, option: true)

        // 1. A hold confirms only while the key and Command are still down.
        var machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        var sequence = machine.pending!.sequence
        expect(machine.holdElapsed(sequence: sequence, keyStillDown: false, commandStillDown: true), D.cancel, "key already up: hold cancels")
        check(!machine.ownedKeyCodes.contains(12), "a key that is up is no longer owned")
        expect(machine.keyUp(keyCode: 12), D.pass, "so a late release passes")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        sequence = machine.pending!.sequence
        expect(machine.holdElapsed(sequence: sequence, keyStillDown: true, commandStillDown: false), D.cancel, "Command already up: hold cancels")
        expect(machine.keyUp(keyCode: 12), D.swallow, "the still held key keeps its release swallowed")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        sequence = machine.pending!.sequence
        expect(machine.holdElapsed(sequence: sequence, keyStillDown: true, commandStillDown: true), D.confirm(.quit, target: 5), "both still down: confirms")

        // 2. A tap disabled mid-hold keeps ownership and swallows repeats.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5)
        machine.interrupted()
        check(machine.pending == nil, "an interruption ends the wait")
        check(machine.hasPressInFlight, "but the press is still in flight")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: true, timestamp: 500 * ms, mode: .hold, target: 5), D.swallow, "a repeat of the owned key is swallowed after the interruption")
        expect(machine.keyUp(keyCode: 12), D.swallow, "and its release")
        check(!machine.hasPressInFlight, "a key-up ends recovery")

        // A press that reached the app unseen while the tap was off.
        machine = QuitGuardStateMachine()
        machine.interrupted()
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: true, timestamp: 0, mode: .hold, target: 5), D.swallow, "a protected repeat with Command is swallowed while recovering")
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: true, timestamp: 0, mode: .off, target: 5), D.pass, "an unprotected repeat passes while recovering")
        expect(machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: true, timestamp: 0, mode: .off, target: 5), D.pass, "ordinary typing passes while recovering")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: QuitGuardModifiers(), isRepeat: true, timestamp: 50 * ms, mode: .hold, target: 5), D.swallow, "the key now owned keeps swallowing its repeats")
        expect(machine.keyUp(keyCode: 12), D.swallow, "its release is swallowed once")
        expect(machine.keyUp(keyCode: 12), D.pass, "then passes")

        machine = QuitGuardStateMachine()
        machine.interrupted()
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .hold, target: 5), D.beginHold(.quit), "a fresh press ends recovery and is judged normally")
        check(!machine.isRecovering, "recovery over after a fresh press")

        // Ownership times out, so a missed release cannot leave it stuck.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.expired(sequence: machine.pending!.sequence)
        check(machine.hasPressInFlight, "owned until released")
        let late = QuitGuardStateMachine.ownershipTimeout + 1_000 * ms
        expect(machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: false, timestamp: late, mode: .off, target: 5), D.pass, "a later key passes")
        check(!machine.hasPressInFlight, "a key not seen for the timeout is dropped")
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: true, timestamp: 9_000 * ms, mode: .doublePress, target: 5), D.swallow, "repeats refresh ownership")
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: true, timestamp: 18_000 * ms, mode: .doublePress, target: 5), D.swallow, "still owned while repeats keep coming")
        machine = QuitGuardStateMachine()
        machine.interrupted()
        _ = machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: true, timestamp: 0, mode: .off, target: 5)
        _ = machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: true, timestamp: late, mode: .off, target: 5)
        check(!machine.isRecovering, "recovery itself times out")
        machine.interrupted()
        machine.reset()
        check(!machine.hasPressInFlight, "reset clears recovery too")

        // 4. Layouts.
        expect(QuitGuardKey.matching(character: "й", keyCode: 12), .quit, "Cyrillic falls back to the key position")
        expect(QuitGuardKey.matching(character: "ς", keyCode: 13), .close, "Greek falls back to the key position")
        expect(QuitGuardKey.matching(character: "'", keyCode: 12), nil, "ASCII punctuation (Dvorak) is its own shortcut")
        expect(QuitGuardKey.matching(character: "q", keyCode: 7), .quit, "a Latin character wins over the key position")
        expect(QuitGuardKey.matching(character: "", keyCode: 12), .quit, "an empty character uses the key position")
        expect(QuitGuardKey.matching(character: "й", keyCode: 0), nil, "a non-Latin key elsewhere is nothing")

        // 5. Log Out and Lock Screen always pass, and Quit confirms with Option.
        machine = QuitGuardStateMachine()
        machine.extraModifier = .shift
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .extraModifier, target: 5), D.showModifierHint(.quit, .option), "the Quit hint asks for Option, not Shift")
        _ = machine.keyUp(keyCode: 12)
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdShift, isRepeat: false, timestamp: 100 * ms, mode: .extraModifier, target: 5), D.pass, "Shift-Command-Q (Log Out) passes")
        check(machine.pending == nil, "and ends the wait")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdControl, isRepeat: false, timestamp: 200 * ms, mode: .extraModifier, target: 5), D.pass, "Control-Command-Q (Lock Screen) passes")
        machine.extraModifier = .control
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdControl, isRepeat: false, timestamp: 300 * ms, mode: .extraModifier, target: 5), D.pass, "Lock Screen passes even with Control chosen")
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmdOption, isRepeat: false, timestamp: 400 * ms, mode: .extraModifier, target: 5), D.confirm(.quit, target: 5), "Option-Command-Q confirms Quit")
        _ = machine.keyUp(keyCode: 12)
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmdControl, isRepeat: false, timestamp: 500 * ms, mode: .extraModifier, target: 5), D.confirm(.close, target: 5), "Close keeps the chosen modifier")
        expect(QuitGuardModifier.shift.effective(for: .close), .shift, "Close is unchanged")
        expect(QuitGuardModifier.control.effective(for: .quit), .option, "Quit never uses Control")
        check(!QuitGuardModifiers(command: true, shift: true, control: true).isSystemQuitChord, "Shift and Control together is no system chord")
        check(!QuitGuardModifiers(command: true, shift: true, option: true).isSystemQuitChord, "with Option it is no system chord")

        // 7. Close with no readable window.
        typealias V = QuitGuardCloseCheck.Verdict
        expect(QuitGuardCloseCheck.verdict(captured: .window, current: .window, sameWindow: true), V.post, "same window closes")
        expect(QuitGuardCloseCheck.verdict(captured: .window, current: .window, sameWindow: false), V.windowChanged, "another window does not")
        expect(QuitGuardCloseCheck.verdict(captured: nil, current: .window, sameWindow: false), V.post, "one press confirm with a window")
        expect(QuitGuardCloseCheck.verdict(captured: .window, current: .noFocusedWindow, sameWindow: false), V.noWindow, "no window now has its own message")
        expect(QuitGuardCloseCheck.verdict(captured: nil, current: .noFocusedWindow, sameWindow: false), V.noWindow, "no window, one press")
        expect(QuitGuardCloseCheck.verdict(captured: .unreadable, current: .unreadable, sameWindow: false), V.post, "an app that cannot be read gets its Command-W")
        expect(QuitGuardCloseCheck.verdict(captured: nil, current: .unreadable, sameWindow: false), V.post, "also for a one press confirm")
        expect(QuitGuardCloseCheck.verdict(captured: .window, current: .unreadable, sameWindow: false), V.windowChanged, "a window that stopped answering is not closed")
        expect(QuitGuardCloseCheck.verdict(captured: .unreadable, current: .window, sameWindow: false), V.windowChanged, "a capture that never answered cannot vouch for a window")
        expect(QuitGuardCloseCheck.verdict(captured: .noFocusedWindow, current: .window, sameWindow: false), V.windowChanged, "a window that appeared since is not closed")

        // 8. A Command-W whose effect cannot be seen (a tab closed, title
        // and count unchanged) is never reported as a failure: the post
        // check and its "could not confirm" note are gone (chunk 1 re-check;
        // the service source guard checks the message stays gone).

        // 9. Quit on close re-arms only on a new work window, never on a
        // dialog, even after the user activated the app (chunk 1 re-check).
        typealias K = QuitOnCloseWindowKind
        var episodes = QuitOnCloseEpisodes()
        episodes.requestedQuit(7)
        episodes.sawWindow(of: 7, kind: .ordinary)
        check(episodes.hasRequestedQuit(7), "an ordinary window alone does not re-arm")
        episodes.activated(7)
        episodes.sawWindow(of: 7, kind: .dialog)
        check(episodes.hasRequestedQuit(7), "activating the quit confirmation dialog does not re-arm")
        episodes.sawWindow(of: 7, kind: .unknown)
        check(episodes.hasRequestedQuit(7), "an unreadable window after activation does not re-arm")
        episodes.sawWindow(of: 7, kind: .ordinary)
        check(!episodes.hasRequestedQuit(7), "an ordinary window after an activation re-arms")
        episodes.requestedQuit(9)
        episodes.sawWindow(of: 9, kind: .standard)
        check(!episodes.hasRequestedQuit(9), "a standard work window re-arms")
        episodes.activated(8)
        episodes.requestedQuit(8)
        episodes.sawWindow(of: 8, kind: .ordinary)
        check(episodes.hasRequestedQuit(8), "an activation before the request does not count")
        expect(K.classify(subrole: "AXStandardWindow", isModal: false), K.standard, "standard and not modal")
        expect(K.classify(subrole: "AXStandardWindow", isModal: true), K.dialog, "a modal window with a standard subrole is a dialog")
        expect(K.classify(subrole: "AXStandardWindow", isModal: nil), K.unknown, "an unreadable modal flag is a doubt")
        expect(K.classify(subrole: "AXDialog", isModal: false), K.dialog, "a dialog subrole is a dialog")
        expect(K.classify(subrole: "AXSystemDialog", isModal: nil), K.dialog, "a system dialog is a dialog")
        expect(K.classify(subrole: "AXFloatingWindow", isModal: false), K.dialog, "a panel is a dialog")
        expect(K.classify(subrole: "AXUnknown", isModal: false), K.dialog, "an unknown subrole never re-arms")
        expect(K.classify(subrole: nil, isModal: false), K.unknown, "no subrole is a doubt")
        expect(K.classify(subrole: "AXCustomWindow", isModal: false), K.ordinary, "a readable custom subrole is ordinary")
        expect([K.dialog, K.standard, K.unknown].max(), K.standard, "the strongest window decides")

        // 12. Ownership never expires out from under a held key (chunk 1
        // re-check): a repeat after a long gap and a release after a long
        // hold are both still swallowed.
        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.expired(sequence: machine.pending!.sequence)
        expect(machine.keyDown(key: .close, keyCode: 13, modifiers: cmd, isRepeat: true, timestamp: late, mode: .doublePress, target: 5), D.swallow, "a repeat after more than the timeout is still swallowed")
        check(machine.hasPressInFlight, "and refreshes ownership")
        expect(machine.keyUp(keyCode: 13, timestamp: late + 1 * ms), D.swallow, "its release is swallowed")
        expect(machine.keyUp(keyCode: 13, timestamp: late + 2 * ms), D.pass, "only once")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.expired(sequence: machine.pending!.sequence)
        _ = machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: false, timestamp: late, mode: .off, target: 5)
        check(!machine.hasPressInFlight, "a quiet key leaves flight (key repeat off, long hold)")
        check(machine.remembers(keyCode: 12), "but is still remembered")
        expect(machine.keyUp(keyCode: 12, timestamp: late * 2), D.swallow, "so its release after a long hold is swallowed")
        check(!machine.remembers(keyCode: 12), "and the release ends ownership")

        machine = QuitGuardStateMachine()
        _ = machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: 0, mode: .doublePress, target: 5)
        _ = machine.expired(sequence: machine.pending!.sequence)
        _ = machine.keyDown(key: nil, keyCode: 0, modifiers: QuitGuardModifiers(), isRepeat: false, timestamp: late, mode: .off, target: 5)
        expect(machine.keyDown(key: .quit, keyCode: 12, modifiers: cmd, isRepeat: false, timestamp: late + 1 * ms, mode: .doublePress, target: 5), D.beginDoublePress(.quit), "a fresh press of a quiet key is judged anew")
        machine.reset()
        check(!machine.remembers(keyCode: 12), "reset forgets quiet keys")

        // 13. The focus owner cache (chunk 1 re-check): only a fresh answer
        // naming another app's family turns protection off.
        typealias P = QuitGuardProcess
        let safari = P(pid: 10, bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app", parentPid: 1)
        let spotlight = P(pid: 20, bundleIdentifier: "com.apple.Spotlight", bundlePath: "/System/Library/CoreServices/Spotlight.app", parentPid: 1)
        var cache = QuitGuardFocusCache()
        check(!cache.stepsAside(front: safari, now: 0), "unknown owner protects")
        var generation = cache.generation
        check(cache.store(spotlight, readAt: 100 * ms, startedAt: generation), "a current read is stored")
        check(cache.stepsAside(front: safari, now: 200 * ms), "a fresh read of a panel steps aside")
        check(!cache.stepsAside(front: safari, now: 100 * ms + QuitGuardFocusCache.maxAge + 1), "a stale read protects")
        cache.invalidate()
        check(!cache.stepsAside(front: safari, now: 200 * ms), "after focus may have moved (Escape with Command held) it protects")
        check(!cache.store(spotlight, readAt: 300 * ms, startedAt: generation), "a read that started before the invalidation is dropped")
        check(!cache.stepsAside(front: safari, now: 300 * ms), "so the old panel answer cannot come back")
        generation = cache.generation
        cache.store(safari, readAt: 400 * ms, startedAt: generation)
        check(!cache.stepsAside(front: safari, now: 400 * ms), "the front app itself protects")
        check(!cache.stepsAside(front: nil, now: 400 * ms), "no front app: nothing to step aside from")

        // 14. Helpers of the front app agree with it.
        let chrome = P(pid: 30, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", parentPid: 1)
        check(P(pid: 31, bundleIdentifier: "com.google.Chrome.helper", bundlePath: nil, parentPid: 1).belongs(to: chrome), "bundle id under the front app")
        check(P(pid: 32, bundleIdentifier: "x.y", bundlePath: "/Applications/Google Chrome.app/Contents/Frameworks/H.app", parentPid: 1).belongs(to: chrome), "bundle inside the front app")
        check(P(pid: 33, bundleIdentifier: nil, bundlePath: nil, parentPid: 30).belongs(to: chrome), "child process")
        check(!P(pid: 34, bundleIdentifier: "com.google.Chromecast", bundlePath: "/Applications/Google Chrome.app2/X.app", parentPid: 1).belongs(to: chrome), "a lookalike prefix is not family")
        check(!chrome.belongs(to: P(pid: 35, bundleIdentifier: "com.google.Chrome.helper", bundlePath: nil, parentPid: 1)), "one way only: the front app is not part of a helper")
        check(!spotlight.belongs(to: safari), "Spotlight is not Safari")
        cache.store(P(pid: 31, bundleIdentifier: "com.google.Chrome.helper", bundlePath: nil, parentPid: 1), readAt: 500 * ms, startedAt: cache.generation)
        check(!cache.stepsAside(front: chrome, now: 500 * ms), "a helper owning focus keeps protection on")

        // 15. Tap rebuild tries reset after a recovery that held.
        var retry = QuitGuardTapRetry()
        var now: TimeInterval = 0
        for round in 1...8 {
            check(retry.died(now: now) != nil, "spaced recovery \(round) still retries")
            now += 1
            retry.confirmedEnabled(now: now)
            now += QuitGuardTapRetry.stableSeconds + 1
        }
        retry = QuitGuardTapRetry()
        var delays: [TimeInterval] = []
        now = 0
        while let delay = retry.died(now: now) {
            delays.append(delay)
            now += delay
            retry.confirmedEnabled(now: now)
            now += 0.1
        }
        expect(delays.count, QuitGuardTapRetry.maxRetries, "a tap that dies right after each rebuild stops after the cap")
        check(delays == delays.sorted() && delays.last! > delays.first!, "and backs off")
        retry.reset()
        check(retry.died(now: now) != nil, "switching protection off and on starts over")

        // 11. Overrides are one per bundle id, whatever the case.
        let policy = QuitGuardPolicy(
            defaultMode: .hold,
            overrides: ["com.Apple.Safari": .off, "com.apple.safari": .doublePress, " com.x ": .extraModifier, "": .off],
            protectsQuit: true,
            protectsClose: true
        )
        expect(policy.overrides.count, 2, "case duplicates and blanks collapse")
        expect(policy.mode(for: "COM.APPLE.SAFARI", key: .quit), .off, "the first spelling in sorted order wins, every time")
        check(policy.overrides["com.Apple.Safari"] != nil, "display spelling kept")
        expect(policy.mode(for: "com.x", key: .close), .extraModifier, "trimmed key matches")
        var edited = policy
        edited.overrides["COM.X"] = .off
        expect(edited.overrides.count, 2, "an edit that differs only in case does not add a duplicate")

        print("Quit guard review checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
