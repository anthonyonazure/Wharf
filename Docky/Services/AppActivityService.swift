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
        // Polled rather than event-driven: macOS has no notification for "this
        // app stopped answering". Two seconds is frequent enough to catch a
        // beachball while staying off the main thread's critical path.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUnresponsive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshUnresponsive() {
        var hung: Set<String> = []
        var stillLaunching: Set<String> = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier else { continue }
            if isUnresponsive(pid: app.processIdentifier) {
                hung.insert(bundleID)
            }
            // Polled rather than observed with KVO: an NSRunningApplication can
            // be deallocated while an observer is still attached, which macOS
            // warns about and later crashes on.
            if !app.isFinishedLaunching, launching.contains(bundleID) {
                stillLaunching.insert(bundleID)
            }
        }

        if launching != stillLaunching {
            launching = stillLaunching
        }
        guard hung != unresponsive else { return }
        unresponsive = hung
    }

    /// Asks the accessibility API for the app's focused window and treats a
    /// timeout as "not answering". `AXUIElementSetMessagingTimeout` bounds the
    /// call so a hung app cannot stall the poll itself.
    private func isUnresponsive(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Float(unresponsiveThreshold))
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
        return result == .cannotComplete
    }

    private static func bundleID(_ notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }
}
