//
//  FocusAndSpacesSafetyLogic.swift
//  Wharf
//
//  The safety decisions added in code review chunk 2 for focus follows mouse
//  and fixed Space order, kept apart from AppKit so every case can be checked
//  without real windows, displays or a real Dock (see
//  scripts/test-focus-and-wintap.sh):
//
//  - Which saved displays are connected, so a monitor that is gone does not
//    keep hover focus installed.
//  - The hover lookup ticket: a lookup that misses its deadline is abandoned
//    and its late answer ignored.
//  - Fixed Space order: the write sequence with its failures reported (never
//    turning the user's switch off), the retry schedule, and what the Dock's
//    stored value allows.
//  - Dock restarts: whether a restart recorded earlier is still owed, and
//    whether a new request can ride on one already under way.
//
//  Foundation and CoreGraphics only, every type nonisolated.
//

import CoreGraphics
import Foundation

// MARK: - Focus follows mouse: displays

nonisolated enum FocusDisplaySelection {
    /// True when at least one display the user turned on is connected now.
    static func hasConnectedMatch(saved: [String], connected: [String]) -> Bool {
        saved.contains { connected.contains($0) }
    }

    /// Saved displays that are not connected now, in saved order.
    static func disconnected(saved: [String], connected: [String]) -> [String] {
        saved.filter { !connected.contains($0) }
    }
}

// MARK: - Focus follows mouse: lookup deadline

/// One Accessibility lookup at a time, each with a ticket. A lookup is
/// settled once, either by its answer or by its deadline, whichever comes
/// first; the other one is then ignored.
nonisolated struct HoverLookupTicket: Equatable {
    private(set) var inFlight: UInt64?
    private var last: UInt64 = 0

    var isBusy: Bool { inFlight != nil }

    mutating func begin() -> UInt64 {
        last &+= 1
        inFlight = last
        return last
    }

    /// Settles `ticket`. True when it was still pending, so the caller acts
    /// on it; false for a late answer or a second settlement.
    mutating func settle(_ ticket: UInt64) -> Bool {
        guard inFlight == ticket else { return false }
        inFlight = nil
        return true
    }
}

// MARK: - Fixed Space order: what the stored value allows

nonisolated enum SpacesOrderAvailability: Equatable {
    case available
    /// A management profile forces the value.
    case managed
    /// Stored as something other than a Boolean; Wharf never writes over it.
    case unsupportedValue

    static func from(raw: Any?, isForced: Bool) -> SpacesOrderAvailability {
        if isForced { return .managed }
        guard let raw else { return .available }
        return raw is NSNumber ? .available : .unsupportedValue
    }
}

// MARK: - Fixed Space order: the write sequence

nonisolated enum SpacesOrderFailure: Equatable {
    /// Wharf's own recovery record could not be saved and confirmed.
    case journalNotSaved
    /// The Dock did not take "do not rearrange".
    case dockNotWritten
    /// The Dock did not take the setting being put back.
    case restoreNotWritten
}

nonisolated enum SpacesOrderOutcome: Equatable {
    case done
    /// The user turned rearranging back on themselves: the caller turns the
    /// switch off to match. The only outcome that changes the switch.
    case letGo
    /// Something did not take. The user's switch stays as it is and the
    /// caller tries again later.
    case failed(SpacesOrderFailure)
}

/// Runs one `SpacesOrderPlan` step against a store. The store is passed in
/// as closures so the order of writes, and what happens when each one fails,
/// can be checked with an in-memory store.
nonisolated struct SpacesOrderRunner {
    var journal: () -> SpacesOrderJournal?
    /// Saves (nil clears) the journal; false when it could not be confirmed.
    var saveJournal: (SpacesOrderJournal?) -> Bool
    var current: () -> SpacesRearrangeSetting
    /// Writes `mru-spaces` (nil removes it); false when it did not take.
    var writeDock: (Bool?) -> Bool
    var restartDock: () -> Void

    func run(wanted: Bool) -> SpacesOrderOutcome {
        let saved = journal()
        switch SpacesOrderPlan.step(wanted: wanted, current: current(), journal: saved) {
        case .none:
            return .done
        case let .hold(restore):
            // Without a confirmed record of what to put back, the Dock is
            // not touched at all.
            guard saveJournal(SpacesOrderJournal(restore: restore, phase: .pendingHold)) else {
                return .failed(.journalNotSaved)
            }
            guard writeDock(false) else { return .failed(.dockNotWritten) }
            let marked = saveJournal(SpacesOrderJournal(restore: restore, phase: .held))
            restartDock()
            // A pending journal over a Dock that reads off is finished by the
            // next run (confirmHold).
            return marked ? .done : .failed(.journalNotSaved)
        case .confirmHold:
            guard let saved else { return .done }
            return saveJournal(SpacesOrderJournal(restore: saved.restore, phase: .held))
                ? .done : .failed(.journalNotSaved)
        case .remember:
            return saveJournal(SpacesOrderJournal(restore: SpacesOrderPlan.restoreOff, phase: .held))
                ? .done : .failed(.journalNotSaved)
        case let .release(removeKey):
            guard let saved else { return .done }
            guard saveJournal(SpacesOrderJournal(restore: saved.restore, phase: .pendingRelease)) else {
                return .failed(.journalNotSaved)
            }
            // The journal stays on failure, so a retry still knows what to
            // put back.
            guard writeDock(removeKey ? nil : true) else { return .failed(.restoreNotWritten) }
            let cleared = saveJournal(nil)
            restartDock()
            return cleared ? .done : .failed(.journalNotSaved)
        case .forget:
            return saveJournal(nil) ? .done : .failed(.journalNotSaved)
        case .letGo:
            _ = saveJournal(nil)
            return .letGo
        }
    }
}

/// When to try a failed change again: a few times, further apart each time,
/// then not until the next launch, the next Dock start or the next toggle.
nonisolated enum SpacesOrderRetryPolicy {
    static let delays: [TimeInterval] = [5, 30, 120]

    /// The wait before retry number `attempt` (1 based), or nil once the
    /// retries are used up.
    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

// MARK: - Dock restarts

nonisolated enum DockRestartDecision: Equatable {
    /// No restart is owed.
    case nothing
    /// The Dock already restarted (or the Mac did): clear the record.
    case clear
    /// The same Dock is still running: restart it.
    case restart
    /// Out of attempts: clear the record and leave the Dock alone. It picks
    /// the change up when it next starts.
    case giveUp
}

/// One process, told apart from a later process that reuses its ID by the
/// time the kernel says it started (microseconds since 1970). Saved as
/// "pid:start".
nonisolated struct DockProcessIdentity: Hashable {
    let pid: pid_t
    let startMicroseconds: Int64

    var stored: String { "\(pid):\(startMicroseconds)" }

    init(pid: pid_t, startMicroseconds: Int64) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let pid = pid_t(parts[0]), let start = Int64(parts[1]), pid > 0 else {
            return nil
        }
        self.init(pid: pid, startMicroseconds: start)
    }
}

nonisolated enum DockRestartPlan {
    /// The most restarts one change may cost, across launches.
    static let maximumAttempts = 3

    /// Whether a restart recorded earlier is still owed. `recorded` are the
    /// Dock processes that may still use the old value, `running` the Dock
    /// processes now (nil for one whose start time could not be read). The
    /// boot sessions are the kernel's ID for each boot, saved with the record
    /// and read now; a different one means the Mac restarted. No clocks are
    /// compared, so sleep never looks like a reboot.
    ///
    /// Restart only when every running Dock is provably one recorded: same
    /// process ID and same start time. Anything less is grounds to leave the
    /// Dock alone.
    static func decide(pending: Bool, recorded: Set<DockProcessIdentity>, running: [DockProcessIdentity?],
                       savedBootSession: String?, currentBootSession: String?,
                       attempts: Int) -> DockRestartDecision {
        guard pending else { return .nothing }
        // A different boot: the Dock running now started after the change.
        if let savedBootSession, let currentBootSession, savedBootSession != currentBootSession {
            return .clear
        }
        // Not running: it reads the preference when it next starts.
        if running.isEmpty { return .clear }
        // A Dock that is not provably a recorded one has restarted, or cannot
        // be told apart from one that has. Without a record (an earlier build
        // saved process IDs only), the same: when unsure, do nothing.
        if recorded.isEmpty || !running.allSatisfy({ $0.map(recorded.contains) ?? false }) {
            return .clear
        }
        return attempts < maximumAttempts ? .restart : .giveUp
    }

    /// How long a restart counts as under way.
    static let coalesceWindow: TimeInterval = 5

    /// Whether a new restart request can be dropped because one is under
    /// way: asked for moments ago, and no Dock other than the ones asked to
    /// quit has started since. The Dock that comes up next reads the
    /// preferences as they are now, so it needs no second restart. A Dock
    /// that already came back is restarted again.
    static func canCoalesce(killedPIDs: Set<pid_t>, killedAt: TimeInterval?, now: TimeInterval,
                            runningPIDs: [pid_t]) -> Bool {
        guard let killedAt, !killedPIDs.isEmpty, now >= killedAt, now - killedAt < coalesceWindow else {
            return false
        }
        return runningPIDs.allSatisfy { killedPIDs.contains($0) }
    }
}

/// What a request to the shared Dock restart gate came to.
nonisolated enum DockRestartResult: Equatable {
    /// No Dock was running; it reads the preferences when it starts.
    case notRunning
    /// Every running Dock accepted the request to quit.
    case submitted(Set<pid_t>)
    /// Rode on a restart already under way.
    case joined(Set<pid_t>)
    /// At least one running Dock did not accept the request: the change is
    /// not applied yet, so callers keep their recovery state.
    case refused

    /// True when the Dock will read the preferences as they are now.
    var willApply: Bool { self != .refused }
}

/// The gate's memory of the last restart it submitted. Only Docks that
/// accepted the request are recorded, so a request that failed is never
/// joined by a later one.
nonisolated struct DockRestartLedger {
    private(set) var killedPIDs: Set<pid_t> = []
    private(set) var killedAt: TimeInterval?

    func canJoin(now: TimeInterval, runningPIDs: [pid_t]) -> Bool {
        DockRestartPlan.canCoalesce(killedPIDs: killedPIDs, killedAt: killedAt, now: now, runningPIDs: runningPIDs)
    }

    /// Records the outcome of asking `requested` to quit, of which
    /// `accepted` took the request. Nothing accepted leaves the ledger as it
    /// was. A Dock that refused stays out of the record, so it is never
    /// mistaken for one on its way out.
    mutating func record(requested: Set<pid_t>, accepted: Set<pid_t>, at now: TimeInterval) -> DockRestartResult {
        guard !requested.isEmpty else { return .notRunning }
        let taken = accepted.intersection(requested)
        guard !taken.isEmpty else { return .refused }
        killedPIDs = taken
        killedAt = now
        return taken == requested ? .submitted(taken) : .refused
    }
}
