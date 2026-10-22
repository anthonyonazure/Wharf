//
//  FocusSpacesSafetyTests.swift
//  Wharf
//
//  Regression checks for code review chunk 2 (focus follows mouse and fixed
//  Space order). Compiled with FocusAndWinTapLogic.swift and
//  FocusAndSpacesSafetyLogic.swift into a second small executable.
//  Run: scripts/test-focus-and-wintap.sh
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

// MARK: - Hover

private func testCommitCheckNeedsPositiveMatch() {
    let point = CGPoint(x: 10, y: 10)
    var check = HoverCommitCheck(livePointer: point, receivingWindowID: nil)
    expect(!check.allowsRaise(of: 7, restingAt: point), "unknown receiving window: no raise")
    check.receivingWindowID = 7
    expect(check.allowsRaise(of: 7, restingAt: point), "same receiving window: raise")
    check.receivingWindowID = 0
    expect(!check.allowsRaise(of: 7, restingAt: point), "window number 0 is not a match")
}

private func testMenuDetection() {
    let own: pid_t = 1
    let front: pid_t = 10
    let agent: pid_t = 20
    let regular: pid_t = 30
    func menu(_ pid: pid_t) -> HoverWindowInfo {
        HoverWindowInfo(windowID: CGWindowID(pid), ownerPID: pid, layer: HoverWindowScan.popUpMenuLayer,
                        bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
    }
    let owners: Set<pid_t> = [front, agent]
    expect(!HoverWindowScan.isMenuOpen(in: [menu(own)], ownPID: own, menuOwnerPIDs: owners),
           "Wharf's own window at the menu level is not another app's menu")
    expect(HoverWindowScan.isMenuOpen(in: [menu(front)], ownPID: own, menuOwnerPIDs: owners),
           "frontmost app's menu counts")
    expect(HoverWindowScan.isMenuOpen(in: [menu(agent)], ownPID: own, menuOwnerPIDs: owners),
           "menu bar extra's menu counts")
    expect(!HoverWindowScan.isMenuOpen(in: [menu(regular)], ownPID: own, menuOwnerPIDs: owners),
           "a background regular app's panel at the menu level does not block hover")
    let normal = HoverWindowInfo(windowID: 5, ownerPID: front, layer: 0, bounds: .zero)
    expect(!HoverWindowScan.isMenuOpen(in: [normal], ownPID: own, menuOwnerPIDs: owners),
           "ordinary windows are not menus")
}

private func testFrontmostSkips() {
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let full = HoverWindowInfo(windowID: 1, ownerPID: 10, layer: 0, bounds: display)
    let small = HoverWindowInfo(windowID: 2, ownerPID: 10, layer: 0, bounds: CGRect(x: 0, y: 25, width: 800, height: 600))
    expect(HoverWindowScan.isFullScreen(pid: 10, in: [full], displayBounds: [display]), "covers the display: full screen")
    expect(!HoverWindowScan.isFullScreen(pid: 10, in: [small], displayBounds: [display]), "ordinary window: not full screen")
    expect(!HoverWindowScan.isFullScreen(pid: 11, in: [full], displayBounds: [display]), "another app's window does not count")
    expect(!HoverWindowScan.isFullScreen(pid: nil, in: [full], displayBounds: [display]), "no frontmost app: not full screen")

    var input = HoverFocusInput()
    input.ownPID = 1
    input.target = HoverWindowInfo(windowID: 42, ownerPID: 100, layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
    input.targetBundleID = "com.example.editor"
    input.frontmostPID = 200
    input.frontmostBundleID = "com.Example.Game"
    expect(HoverFocusGate.decide(input) == .raise(windowID: 42, pid: 100), "baseline raises")
    var copy = input
    copy.excludedBundleIDs = BundleIDList.matchSet(["com.example.game"])
    expect(HoverFocusGate.decide(copy) == .skip(.frontmostExcluded), "excluded app in front keeps focus")
    copy = input
    copy.frontmostIsFullScreen = true
    expect(HoverFocusGate.decide(copy) == .skip(.frontmostFullScreen), "full screen app in front keeps focus")
    copy = input
    copy.menuOpen = true
    copy.frontmostIsFullScreen = true
    expect(HoverFocusGate.decide(copy) == .skip(.menuOpen), "menu still checked first")
}

private func testDisplaySelection() {
    typealias D = FocusDisplaySelection
    expect(!D.hasConnectedMatch(saved: ["A"], connected: ["B"]), "only an unplugged display saved: not wanted")
    expect(D.hasConnectedMatch(saved: ["A", "B"], connected: ["B"]), "one saved display connected: wanted")
    expect(!D.hasConnectedMatch(saved: [], connected: ["B"]), "nothing saved: not wanted")
    expect(D.disconnected(saved: ["A", "B", "C"], connected: ["B"]) == ["A", "C"], "unplugged saved displays listed in order")
    expect(D.disconnected(saved: ["B"], connected: ["B"]).isEmpty, "all connected: none listed")
}

private func testLookupTicket() {
    var ticket = HoverLookupTicket()
    expect(!ticket.isBusy, "idle at start")
    let first = ticket.begin()
    expect(ticket.isBusy, "busy while a lookup runs")
    // The watchdog fires first: the lookup is abandoned.
    expect(ticket.settle(first), "deadline settles a pending lookup")
    expect(!ticket.isBusy, "free again after the deadline, so hover keeps working")
    expect(!ticket.settle(first), "the late answer is ignored")
    let second = ticket.begin()
    expect(!ticket.settle(first), "an old answer never settles a newer lookup")
    expect(ticket.isBusy, "newer lookup still pending")
    expect(ticket.settle(second), "its own answer settles it")
    expect(!ticket.settle(second), "the watchdog after an answer does nothing")
}

// MARK: - Fixed Space order

/// An in-memory Dock and journal with switches to make each write fail.
private final class FakeStore {
    var journal: SpacesOrderJournal?
    var dock: SpacesRearrangeSetting = .on
    var failJournalSaves = false
    /// Fail only saves of this phase (nil save is `clearFails`).
    var failPhase: SpacesHoldPhase?
    var clearFails = false
    var failDockWrites = false
    var restarts = 0

    var runner: SpacesOrderRunner {
        SpacesOrderRunner(
            journal: { self.journal },
            saveJournal: { new in
                if self.failJournalSaves { return false }
                if let new, new.phase == self.failPhase { return false }
                if new == nil, self.clearFails { return false }
                self.journal = new
                return true
            },
            current: { self.dock },
            writeDock: { value in
                if self.failDockWrites { return false }
                self.dock = value.map { $0 ? .on : .off } ?? .absent
                return true
            },
            restartDock: { self.restarts += 1 }
        )
    }
}

private func testRunnerHappyPath() {
    let store = FakeStore()
    store.dock = .absent
    expect(store.runner.run(wanted: true) == .done, "turning on works")
    expect(store.dock == .off && store.journal == SpacesOrderJournal(restore: SpacesOrderPlan.restoreAbsent, phase: .held),
           "Dock off, journal held with what to put back")
    expect(store.restarts == 1, "Dock restarted once")
    expect(store.runner.run(wanted: true) == .done && store.restarts == 1, "steady state does nothing")
    expect(store.runner.run(wanted: false) == .done, "turning off works")
    expect(store.dock == .absent && store.journal == nil, "missing key put back, journal cleared")
}

private func testRunnerFailures() {
    // Launch time: the journal cannot be saved. The Dock is left alone and
    // the outcome says failed, never letGo, so the switch stays on.
    var store = FakeStore()
    store.failJournalSaves = true
    expect(store.runner.run(wanted: true) == .failed(.journalNotSaved), "journal save failure reported")
    expect(store.dock == .on && store.restarts == 0, "Dock untouched without a journal")
    store.failJournalSaves = false
    expect(store.runner.run(wanted: true) == .done && store.dock == .off, "retry after a transient failure holds")

    // The Dock write fails: the pending journal stays, the retry finishes.
    store = FakeStore()
    store.failDockWrites = true
    expect(store.runner.run(wanted: true) == .failed(.dockNotWritten), "Dock write failure reported")
    expect(store.journal?.phase == .pendingHold, "pending journal kept for the retry")
    store.failDockWrites = false
    expect(store.runner.run(wanted: true) == .done, "retry succeeds")
    expect(store.journal == SpacesOrderJournal(restore: SpacesOrderPlan.restoreOn, phase: .held), "held with the original value")

    // The Dock took it but the held mark did not: the next run confirms.
    store = FakeStore()
    store.failPhase = .held
    expect(store.runner.run(wanted: true) == .failed(.journalNotSaved), "held mark failure reported")
    expect(store.dock == .off && store.journal?.phase == .pendingHold, "Dock off, journal still pending")
    store.failPhase = nil
    expect(store.runner.run(wanted: true) == .done && store.journal?.phase == .held, "retry confirms the hold")

    // Restore fails (Reset Behavior): the journal is left in place.
    store = FakeStore()
    _ = store.runner.run(wanted: true)
    store.failDockWrites = true
    expect(store.runner.run(wanted: false) == .failed(.restoreNotWritten), "restore failure reported")
    expect(store.journal?.phase == .pendingRelease && store.journal?.restore == SpacesOrderPlan.restoreOn,
           "journal kept with what to put back")
    store.failDockWrites = false
    expect(store.runner.run(wanted: false) == .done && store.dock == .on && store.journal == nil, "retry restores")

    // The journal cannot be cleared after a restore: reported, and the next
    // run clears it without writing the Dock again.
    store = FakeStore()
    _ = store.runner.run(wanted: true)
    store.clearFails = true
    expect(store.runner.run(wanted: false) == .failed(.journalNotSaved), "clear failure reported")
    store.clearFails = false
    let restarts = store.restarts
    expect(store.runner.run(wanted: false) == .done && store.journal == nil, "next run forgets")
    expect(store.restarts == restarts, "no extra Dock restart")

    // The user turned rearranging back on in System Settings.
    store = FakeStore()
    _ = store.runner.run(wanted: true)
    store.dock = .on
    expect(store.runner.run(wanted: true) == .letGo, "user's own change: let go")
    expect(store.journal == nil, "journal cleared on let go")
}

private func testAvailability() {
    typealias A = SpacesOrderAvailability
    expect(A.from(raw: nil, isForced: false) == .available, "missing key is fine")
    expect(A.from(raw: NSNumber(value: false), isForced: false) == .available, "Boolean is fine")
    expect(A.from(raw: "0", isForced: false) == .unsupportedValue, "string value is unsupported")
    expect(A.from(raw: NSNumber(value: true), isForced: true) == .managed, "forced is managed")
}

private func testRetryPolicy() {
    typealias R = SpacesOrderRetryPolicy
    expect(R.delay(forAttempt: 1) == 5, "first retry soon")
    expect(R.delay(forAttempt: 2)! > R.delay(forAttempt: 1)!, "backs off")
    expect(R.delay(forAttempt: 4) == nil, "bounded")
    expect(R.delay(forAttempt: 0) == nil, "attempt numbers start at 1")
}

private func testDockRestartPlan() {
    typealias P = DockRestartPlan
    expect(P.decide(pending: false, killedPIDs: [5], runningPIDs: [5], rebootedSince: false, attempts: 0) == .nothing,
           "nothing pending")
    expect(P.decide(pending: true, killedPIDs: [5], runningPIDs: [9], rebootedSince: false, attempts: 1) == .clear,
           "new Dock process: it restarted, no second restart")
    expect(P.decide(pending: true, killedPIDs: [5], runningPIDs: [5], rebootedSince: false, attempts: 1) == .restart,
           "same Dock still running: restart")
    expect(P.decide(pending: true, killedPIDs: [5], runningPIDs: [5], rebootedSince: false, attempts: P.maximumAttempts) == .giveUp,
           "out of attempts across launches: give up, never flicker every launch")
    expect(P.decide(pending: true, killedPIDs: [5], runningPIDs: [5], rebootedSince: true, attempts: 0) == .clear,
           "a reboot since: the process ID match is a coincidence")
    expect(P.decide(pending: true, killedPIDs: [5], runningPIDs: [], rebootedSince: false, attempts: 0) == .clear,
           "Dock not running: it reads the value at start")
    expect(P.decide(pending: true, killedPIDs: [], runningPIDs: [5], rebootedSince: false, attempts: 0) == .clear,
           "no record from an earlier build: do not kill blindly")

    // The shared gate.
    expect(P.canCoalesce(killedPIDs: [5], killedAt: 100, now: 101, runningPIDs: [5]),
           "old Dock still quitting: ride on that restart")
    expect(P.canCoalesce(killedPIDs: [5], killedAt: 100, now: 101, runningPIDs: []),
           "between Docks: the next one reads the new values")
    expect(!P.canCoalesce(killedPIDs: [5], killedAt: 100, now: 101, runningPIDs: [9]),
           "a new Dock is already up: restart it again")
    expect(!P.canCoalesce(killedPIDs: [5], killedAt: 100, now: 110, runningPIDs: [5]),
           "an old restart does not swallow a new one")
    expect(!P.canCoalesce(killedPIDs: [], killedAt: nil, now: 1, runningPIDs: [5]), "nothing under way")
}

@main
enum FocusSpacesSafetyTests {
    static func main() {
        testCommitCheckNeedsPositiveMatch()
        testMenuDetection()
        testFrontmostSkips()
        testDisplaySelection()
        testLookupTicket()
        testRunnerHappyPath()
        testRunnerFailures()
        testAvailability()
        testRetryPolicy()
        testDockRestartPlan()

        if failures == 0 {
            print("PASS: \(checks) safety checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) safety checks")
            exit(1)
        }
    }
}
