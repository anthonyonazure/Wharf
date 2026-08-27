//
//  AppActivityService.swift
//  Wharf
//
//  Tracks the three transient app states a taskbar is expected to surface:
//  an app asking for attention, an app still launching, and an app that has
//  stopped answering.
//
//  macOS surfaces none of these to a third-party dock directly, so each is
//  derived: attention from the bouncing-icon notification, launching from the
//  gap between launch and finished-launching, and unresponsive from the
//  accessibility API failing to answer within a deadline.
//

import AppKit
import Combine

@MainActor
final class AppActivityService: ObservableObject {
    static let shared = AppActivityService()

    /// Bundle IDs currently demanding attention (what the Dock renders as a
    /// bouncing icon).
    @Published private(set) var attentionRequested: Set<String> = []

    /// Bundle IDs that have launched but not yet finished launching.
    @Published private(set) var launching: Set<String> = []

    /// Bundle IDs whose main thread is not answering accessibility queries.
    @Published private(set) var unresponsive: Set<String> = []

    private var cancellables: Set<AnyCancellable> = []

    /// How long a tile keeps asking for attention before it gives up, matching
    /// roughly how long the system Dock bounces.
    private let attentionDuration: TimeInterval = 6
    private var attentionExpiry: [String: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private let probeQueue = DispatchQueue(label: "wharf.app-activity.probe", qos: .utility)

    /// True while a probe pass is still running. Several hung apps can make a
    /// pass outlast the 2s timer; without this the queue grows and an old,
    /// slower pass finishes last and overwrites current state with stale data.
    private var isProbing = false

    /// How long an app may ignore an accessibility query before it counts as
    /// hung. Deliberately longer than the process-wide 1s AX timeout so a
    /// single slow answer doesn't flag a healthy app.
    private let unresponsiveThreshold: TimeInterval = 3

    // MARK: - Poll pacing
    //
    // Wharf: this poll used to ask every running app, every two seconds,
    // forever. Each question is a synchronous trip into another process, so a
    // desk with thirty apps open paid fifteen cross-process calls a second to
    // learn nothing, and woke every one of those apps to do it. Measured at
    // 21.6% of a core with nobody touching the machine.
    //
    // Two changes, both standard: ask a few apps per tick instead of all of
    // them, and slow down while the answer keeps coming back the same.

    /// How many apps to probe per tick. A hang is still caught, just over a
    /// few ticks rather than one, which is well inside human patience for a
    /// "not responding" label appearing.
    private let probeBatchSize = 5

    /// Where the last batch stopped, so probing walks the app list round robin
    /// instead of restarting at the top and never reaching the tail.
    private var probeCursor = 0

    private let minimumInterval: TimeInterval = 2
    private let maximumInterval: TimeInterval = 12
    private var currentInterval: TimeInterval = 2

    private init() {}

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        center.publisher(for: NSWorkspace.willLaunchApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in
                self?.launching.insert(id)
                self?.quickenPolling()
            }
            .store(in: &cancellables)

        // `didLaunch` fires when the process exists; an app is still bouncing
        // until `finishedLaunching` flips, so clear on both to avoid a badge
        // that never goes away for apps that never set the flag.
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in
                self?.scheduleLaunchClear(for: id)
                self?.quickenPolling()
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in
                self?.launching.remove(id)
                self?.attentionRequested.remove(id)
                self?.unresponsive.remove(id)
                self?.quickenPolling()
            }
            .store(in: &cancellables)

        // Clearing attention when an app comes forward is the one part of
        // this that has a real notification.
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in
                self?.attentionRequested.remove(id)
                self?.quickenPolling()
            }
            .store(in: &cancellables)

        startUnresponsivePolling()
    }

    // MARK: - Attention

    /// Flags an app as demanding attention (what the system Dock renders as a
    /// bouncing icon).
    ///
    /// macOS exposes no public signal for another process calling
    /// `requestUserAttention`, so this is an entry point for code that can
    /// infer it — currently a badge appearing on an app that is not frontmost.
    /// The flag clears as soon as the app is activated.
    func noteAttentionRequested(bundleIdentifier: String) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleIdentifier else { return }
        attentionRequested.insert(bundleIdentifier)

        // Wharf: attention is a moment, not a state. The system Dock bounces
        // for a few seconds and stops, and it has to: an app whose badge has
        // sat there since this morning is not asking for anything. Left
        // permanent, the flag also kept a tile animating forever, which is
        // paid for in CPU on every display.
        attentionExpiry[bundleIdentifier]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.attentionRequested.remove(bundleIdentifier)
            self?.attentionExpiry[bundleIdentifier] = nil
        }
        attentionExpiry[bundleIdentifier] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + attentionDuration, execute: work)
    }

    private func scheduleLaunchClear(for bundleID: String) {
        // Some apps never set finishedLaunching. Clear on a timer so a tile
        // cannot be stuck in the launching state forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.launching.remove(bundleID)
        }
    }

    // MARK: - Unresponsive

    private func startUnresponsivePolling() {
        scheduleNextPoll()
    }

    /// Reschedules itself each time rather than repeating, so the interval can
    /// stretch while nothing is changing and snap back the moment it does.
    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUnresponsive()
                self?.scheduleNextPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Called when something happened that could change an app's state, so the
    /// next answer matters again.
    private func quickenPolling() {
        guard currentInterval != minimumInterval else { return }
        currentInterval = minimumInterval
        scheduleNextPoll()
    }

    private func slowPollingIfSettled(changed: Bool) {
        if changed {
            currentInterval = minimumInterval
        } else {
            currentInterval = min(currentInterval * 1.5, maximumInterval)
        }
    }

    /// True while the screen is locked or the session is not on the console.
    /// Nothing is drawn then, so nothing needs to be asked.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    private func refreshUnresponsive() {
        // Snapshot on the main actor, probe off it.
        //
        // The probe is the whole point of this poll and it is also the danger:
        // querying a hung app blocks the caller until the messaging timeout
        // expires. Running that on the main thread would freeze the dock for
        // up to three seconds per beachballing app, every two seconds — the
        // dock would hang precisely when an app hangs, which is when the user
        // most needs it to work.
        guard !Self.screenIsLocked() else { return }

        let running: [(bundleID: String, pid: pid_t, finishedLaunching: Bool)] =
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap { app in
                    guard let bundleID = app.bundleIdentifier else { return nil }
                    return (bundleID, app.processIdentifier, app.isFinishedLaunching)
                }

        guard !running.isEmpty else { return }
        guard !isProbing else { return }
        isProbing = true

        // Probe a slice, starting where the last tick stopped. Everything
        // outside the slice keeps whatever answer it last gave, so a hung app
        // stays marked hung until its turn comes round again.
        if probeCursor >= running.count { probeCursor = 0 }
        let start = probeCursor
        let count = min(probeBatchSize, running.count)
        let batch = (0..<count).map { running[(start + $0) % running.count] }
        probeCursor = (start + count) % running.count

        let carriedOver = unresponsive.subtracting(batch.map(\.bundleID))
        let currentlyLaunching = launching
        let threshold = unresponsiveThreshold

        probeQueue.async { [weak self] in
            var hung: Set<String> = carriedOver
            var stillLaunching: Set<String> = []

            for candidate in batch {
                if Self.isUnresponsive(pid: candidate.pid, threshold: threshold) {
                    hung.insert(candidate.bundleID)
                }
                // Polled rather than observed with KVO: an NSRunningApplication
                // can be deallocated while an observer is still attached, which
                // macOS warns about and later crashes on.
                if !candidate.finishedLaunching, currentlyLaunching.contains(candidate.bundleID) {
                    stillLaunching.insert(candidate.bundleID)
                }
            }

            Task { @MainActor in
                guard let self else { return }
                self.isProbing = false
                let launchingOutsideBatch = self.launching.subtracting(batch.map(\.bundleID))
                let mergedLaunching = stillLaunching.union(launchingOutsideBatch)
                var changed = false
                if self.launching != mergedLaunching { self.launching = mergedLaunching; changed = true }
                if self.unresponsive != hung { self.unresponsive = hung; changed = true }
                self.slowPollingIfSettled(changed: changed)
            }
        }
    }

    /// Asks the accessibility API for the app's focused window and treats a
    /// timeout as "not answering". Static and pid-based so it carries no actor
    /// isolation and can run on the probe queue.
    nonisolated private static func isUnresponsive(pid: pid_t, threshold: TimeInterval) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Float(threshold))
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        return result == .cannotComplete
    }

    private static func bundleID(_ notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }
}
