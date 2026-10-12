//
//  WindowActionsService.swift
//  Wharf
//
//  The window and process actions a taskbar is expected to offer from a
//  right-click: close every window, force quit, pin a window's size, and
//  toggle fullscreen.
//
//  macOS exposes none of these to a third-party dock as a single call, so each
//  is assembled from the accessibility API or POSIX signals.
//

import AppKit

@MainActor
final class WindowActionsService {
    static let shared = WindowActionsService()

    /// Windows the user has pinned to their current size. Keyed by the same
    /// stable window identifier the registry uses.
    private(set) var sizeLockedWindowIDs: Set<String> = []
    private var lockedSizes: [String: CGSize] = [:]
    private var lockedProcessIDs: [String: pid_t] = [:]
    private var enforcementTimer: Timer?
    private let windows: () -> [AppWindow]
    private let resize: (AppWindow, CGRect) -> Bool
    private let usesEnforcementTimer: Bool
    private let isProcessRunning: (pid_t) -> Bool

    /// The window source, the resize action and the timer are injectable so
    /// tests can run the size-lock logic without touching real windows.
    init(
        windows: @escaping () -> [AppWindow] = { WindowRegistry.shared.windows },
        resize: @escaping (AppWindow, CGRect) -> Bool = { WindowRegistry.shared.resize($0, to: $1) },
        usesEnforcementTimer: Bool = true,
        isProcessRunning: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0) != nil }
    ) {
        self.windows = windows
        self.resize = resize
        self.usesEnforcementTimer = usesEnforcementTimer
        self.isProcessRunning = isProcessRunning
    }

    // MARK: - Close and quit

    /// Closes every window of an app without quitting it.
    ///
    /// Distinct from quitting: a user asking to close all windows usually
    /// wants the app running and empty, which is what Cmd+W repeated would do.
    @discardableResult
    func closeAllWindows(bundleIdentifier: String) -> Int {
        let windows = WorkspaceService.shared.appWindows(bundleIdentifier: bundleIdentifier)
        var closed = 0
        for window in windows where WindowRegistry.shared.close(window) {
            closed += 1
        }
        return closed
    }

    /// Asks the app to quit, the same as Cmd+Q. Work is not lost: an app with
    /// unsaved changes gets to put up its save dialog.
    func quit(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }
    }

    /// Force quits. Unsaved work IS lost, which is why it is separated from
    /// `quit` rather than being a fallback inside it.
    func forceQuit(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.forceTerminate()
        }
    }

    // MARK: - Fullscreen

    /// Whether the window is in native fullscreen, per the accessibility flag
    /// rather than a geometry guess.
    func isFullscreen(_ window: AppWindow) -> Bool {
        WindowRegistry.shared.isFullscreen(window)
    }

    /// Toggles native fullscreen through the accessibility API.
    ///
    /// `AXFullScreen` is the same switch the green button flips, so the window
    /// gets a real fullscreen Space rather than being resized to screen size,
    /// which is what a manual resize would produce.
    @discardableResult
    func toggleFullscreen(_ window: AppWindow) -> Bool {
        WindowRegistry.shared.setFullscreen(window, fullscreen: !isFullscreen(window))
    }

    // MARK: - Size lock

    func isSizeLocked(_ window: AppWindow) -> Bool {
        sizeLockedWindowIDs.contains(window.windowIdentifier)
    }

    /// Pins a window to its current size.
    ///
    /// macOS has no "lock size" flag, so this records the size and puts it
    /// back whenever it changes. Enforced on a timer rather than an observer
    /// because AX resize notifications are unreliable across apps, and a
    /// missed notification would silently unlock the window.
    func toggleSizeLock(_ window: AppWindow) {
        let id = window.windowIdentifier
        if sizeLockedWindowIDs.contains(id) {
            sizeLockedWindowIDs.remove(id)
            lockedSizes.removeValue(forKey: id)
            lockedProcessIDs.removeValue(forKey: id)
            if sizeLockedWindowIDs.isEmpty { stopEnforcing() }
            return
        }

        guard let frame = window.frame else { return }
        sizeLockedWindowIDs.insert(id)
        lockedSizes[id] = frame.size
        lockedProcessIDs[id] = window.processIdentifier
        startEnforcingIfNeeded()
    }

    private func startEnforcingIfNeeded() {
        guard usesEnforcementTimer, enforcementTimer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceLockedSizes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        enforcementTimer = timer
    }

    private func stopEnforcing() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
    }

    func enforceLockedSizes() {
        guard !sizeLockedWindowIDs.isEmpty else {
            stopEnforcing()
            return
        }

        // Only the locked windows, not every window on the system. Scanning
        // them all ran an accessibility query per window every 0.75s to service
        // what is usually a single lock.
        let lockedWindows = windows().filter {
            sizeLockedWindowIDs.contains($0.windowIdentifier)
        }

        for window in lockedWindows {
            let id = window.windowIdentifier
            guard let locked = lockedSizes[id], let frame = window.frame else { continue }
            guard abs(frame.width - locked.width) > 2 || abs(frame.height - locked.height) > 2 else { continue }
            _ = resize(
                window,
                CGRect(origin: frame.origin, size: locked)
            )
        }

        // Drop locks whose window is truly gone, so the timer eventually stops.
        // A window missing from the registry is not necessarily gone: hiding
        // an app removes all of its windows for a while. So a lock is dropped
        // when its app still shows other windows (this one was closed) or
        // when the app process has exited; otherwise it is kept.
        let current = windows()
        let live = Set(current.map(\.windowIdentifier))
        let livePIDs = Set(current.map(\.processIdentifier))
        let stale = sizeLockedWindowIDs.subtracting(live).filter { id in
            guard let pid = lockedProcessIDs[id] else { return true }
            return livePIDs.contains(pid) || !isProcessRunning(pid)
        }
        for id in stale {
            sizeLockedWindowIDs.remove(id)
            lockedSizes.removeValue(forKey: id)
            lockedProcessIDs.removeValue(forKey: id)
        }
    }

    // MARK: - Hiding

    /// Hides an app from every dock. Mirrors the Hidden Apps settings pane, so
    /// the same list backs both the right-click action and the GUI.
    func hideFromDock(bundleIdentifier: String) {
        var hidden = DockyPreferences.shared.hiddenAppBundleIdentifiers
        guard !hidden.contains(bundleIdentifier) else { return }
        hidden.append(bundleIdentifier)
        DockyPreferences.shared.hiddenAppBundleIdentifiers = hidden
    }

    private func screenFor(_ window: AppWindow) -> NSScreen? {
        guard let axFrame = window.frame,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let nsFrame = CGRect(
            x: axFrame.minX,
            y: primaryHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        return NSScreen.screens.max { a, b in
            let areaA = a.frame.intersection(nsFrame)
            let areaB = b.frame.intersection(nsFrame)
            let sizeA = areaA.isNull ? 0 : areaA.width * areaA.height
            let sizeB = areaB.isNull ? 0 : areaB.width * areaB.height
            return sizeA < sizeB
        }
    }
}
