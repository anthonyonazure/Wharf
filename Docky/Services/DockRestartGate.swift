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

    private var ledger = DockRestartLedger()

    private init() {}

    static func runningDockPIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).map(\.processIdentifier)
    }

    /// The running Dock processes with their start times; nil for one whose
    /// start time could not be read (it then never counts as a match).
    static func runningDockIdentities() -> [DockProcessIdentity?] {
        runningDockPIDs().map(processIdentity)
    }

    /// Process ID plus the kernel's start time, nil when the process is gone
    /// or the kernel does not answer.
    static func processIdentity(_ pid: pid_t) -> DockProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return DockProcessIdentity(pid: pid, startMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
    }

    /// The kernel's ID for this boot (kern.bootsessionuuid), nil when it
    /// cannot be read. Unlike uptime it does not depend on sleep or clocks.
    static func bootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let id = String(cString: buffer)
        return id.isEmpty ? nil : id
    }

    /// Restarts the Dock unless a restart is already under way. Only a
    /// request the Dock accepted is remembered for later requests to join;
    /// `.refused` tells the caller the change is not applied yet. Callers
    /// flush their preference writes first.
    @discardableResult
    func restart(reason: String) -> DockRestartResult {
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID)
        let now = ProcessInfo.processInfo.systemUptime
        let running = docks.map(\.processIdentifier)
        if ledger.canJoin(now: now, runningPIDs: running) {
            NSLog("[Wharf] Dock restart for \(reason) joins the one already under way.")
            return .joined(ledger.killedPIDs)
        }
        let accepted = Set(docks.filter { $0.forceTerminate() }.map(\.processIdentifier))
        let result = ledger.record(requested: Set(running), accepted: accepted, at: now)
        if result == .refused {
            NSLog("[Wharf] Dock restart for \(reason): the Dock refused to quit.")
        }
        return result
    }
}
