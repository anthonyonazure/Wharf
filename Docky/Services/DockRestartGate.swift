//
//  DockRestartGate.swift
//  Wharf
//
//  One door for Wharf's Dock restarts. Fixed Space order and hiding the
//  system Dock both restart the Dock to apply a preference, and both can do
//  it in the same run (at launch, or when Reset Behavior turns both off). A
//  request that arrives while a restart is still under way rides on it
//  instead of killing the Dock a second time: the Dock that comes up next
//  reads the preferences as they are by then. A Dock that already came back
//  is restarted again, so no change is ever left unread. The decision lives
//  in DockRestartPlan.canCoalesce.
//

import AppKit

final class DockRestartGate {
    static let shared = DockRestartGate()

    static let dockBundleID = "com.apple.dock"

    private var killedPIDs: Set<pid_t> = []
    private var killedAt: TimeInterval?

    private init() {}

    static func runningDockPIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).map(\.processIdentifier)
    }

    /// Restarts the Dock unless a restart is already under way. Returns the
    /// Dock process IDs that were (or are being) asked to quit; empty when no
    /// Dock was running, which then reads the preferences when it starts.
    /// Callers flush their preference writes first.
    @discardableResult
    func restart(reason: String) -> Set<pid_t> {
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID)
        let now = ProcessInfo.processInfo.systemUptime
        if DockRestartPlan.canCoalesce(killedPIDs: killedPIDs, killedAt: killedAt, now: now,
                                       runningPIDs: docks.map(\.processIdentifier)) {
            NSLog("[Wharf] Dock restart for \(reason) joins the one already under way.")
            return killedPIDs
        }
        guard !docks.isEmpty else { return [] }
        killedPIDs = Set(docks.map(\.processIdentifier))
        killedAt = now
        if !docks.map({ $0.forceTerminate() }).contains(true) {
            NSLog("[Wharf] Dock restart for \(reason): the Dock refused to quit.")
        }
        return killedPIDs
    }
}
