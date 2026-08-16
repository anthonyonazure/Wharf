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
    private var pollTimer: Timer?
    private let probeQueue = DispatchQueue(label: "wharf.app-activity.probe", qos: .utility)

    /// How long an app may ignore an accessibility query before it counts as
    /// hung. Deliberately longer than the process-wide 1s AX timeout so a
    /// single slow answer doesn't flag a healthy app.
    private let unresponsiveThreshold: TimeInterval = 3

    private init() {}

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        center.publisher(for: NSWorkspace.willLaunchApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in self?.launching.insert(id) }
            .store(in: &cancellables)

        // `didLaunch` fires when the process exists; an app is still bouncing
        // until `finishedLaunching` flips, so clear on both to avoid a badge
        // that never goes away for apps that never set the flag.
        center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in self?.scheduleLaunchClear(for: id) }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in
                self?.launching.remove(id)
                self?.attentionRequested.remove(id)
                self?.unresponsive.remove(id)
            }
            .store(in: &cancellables)

        // Clearing attention when an app comes forward is the one part of
        // this that has a real notification.
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap(Self.bundleID)
            .sink { [weak self] id in self?.attentionRequested.remove(id) }
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
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUnresponsive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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
        let candidates: [(bundleID: String, pid: pid_t, finishedLaunching: Bool)] =
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap { app in
                    guard let bundleID = app.bundleIdentifier else { return nil }
                    return (bundleID, app.processIdentifier, app.isFinishedLaunching)
                }

        let currentlyLaunching = launching
        let threshold = unresponsiveThreshold

        probeQueue.async { [weak self] in
            var hung: Set<String> = []
            var stillLaunching: Set<String> = []

            for candidate in candidates {
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
                if self.launching != stillLaunching { self.launching = stillLaunching }
                if self.unresponsive != hung { self.unresponsive = hung }
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
