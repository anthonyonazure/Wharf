//
//  QuitOnCloseService.swift
//  Wharf
//
//  Quits an app on the user's list once its last window closes, the way a
//  Windows app ends with its window. Only a normal quit request is sent, so
//  an app with unsaved changes still asks what to do and can refuse.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): AutoQuitService's rules that an app must have shown a
//  window first, that a hidden app is not a closed one, and that the check
//  waits out the closing window's fade. Vorssaint quits every app except a
//  list; Wharf quits only the apps on its list.
//
//  Window changes come from WindowRegistry, which already watches every
//  regular app, so this adds no Accessibility observers of its own. Every
//  doubt keeps the app running: see QuitOnCloseLogic.shouldQuit.
//

import AppKit
import Combine

final class QuitOnCloseService {
    static let shared = QuitOnCloseService()

    private let preferences = WindowBehaviorPreferences.shared
    private let registry = WindowRegistry.shared
    private var cancellables: Set<AnyCancellable> = []
    private var windowsSubscription: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?

    /// Listed apps that have shown a window since watching began.
    private var hadWindow: Set<pid_t> = []
    /// Apps that had a window on the previous registry update.
    private var hasWindowNow: Set<pid_t> = []
    /// The current round of looks per app; a look from an older round, or
    /// after a look that found a window, does nothing.
    private var rounds: [pid_t: Int] = [:]
    private var nextRound = 0

    private init() {}

    func start() {
        observeChanges { [weak self] in
            _ = WindowBehaviorPreferences.shared.quitOnCloseEnabled
            _ = WindowBehaviorPreferences.shared.quitOnCloseApps
            self?.sync()
        }
        .store(in: &cancellables)

        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
    }

    private var isActive: Bool {
        preferences.quitOnCloseEnabled && !preferences.quitOnCloseApps.isEmpty && AXIsProcessTrusted()
    }

    private func sync() {
        guard isActive else {
            windowsSubscription = nil
            if let terminateObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            }
            terminateObserver = nil
            hadWindow.removeAll()
            hasWindowNow.removeAll()
            return
        }

        if windowsSubscription == nil {
            windowsSubscription = registry.$windows
                .receive(on: DispatchQueue.main)
                .sink { [weak self] windows in self?.windowsChanged(windows) }
        }
        if terminateObserver == nil {
            terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.hadWindow.remove(app.processIdentifier)
                self?.hasWindowNow.remove(app.processIdentifier)
            }
        }
        // A list change may have removed apps that were being watched.
        hadWindow = hadWindow.filter { isListed(pid: $0) }
        windowsChanged(registry.windows)
    }

    private func windowsChanged(_ windows: [AppWindow]) {
        guard isActive else { return }
        let list = preferences.quitOnCloseApps
        let current = Set(
            windows
                .filter { WindowBehaviorBundleList.contains($0.bundleIdentifier, in: list) }
                .map(\.processIdentifier)
        )
        hadWindow.formUnion(current)

        // Apps that just went from some windows to none.
        for pid in hasWindowNow.subtracting(current) where hadWindow.contains(pid) {
            scheduleChecks(for: pid)
        }
        hasWindowNow = current
    }

    private func scheduleChecks(for pid: pid_t) {
        nextRound += 1
        let round = nextRound
        rounds[pid] = round
        for delay in QuitOnCloseLogic.checkDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkAndQuit(pid: pid, round: round, isFinalLook: delay == QuitOnCloseLogic.checkDelays.last)
            }
        }
    }

    /// Looks several times; only the last look may quit, and only when every
    /// look in between agreed there was nothing left. A window that came back
    /// (a full screen exit recreates its window) ends the round.
    private func checkAndQuit(pid: pid_t, round: Int, isFinalLook: Bool) {
        guard isActive, hadWindow.contains(pid), rounds[pid] == round else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            hadWindow.remove(pid)
            return
        }

        let serverWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let facts = QuitOnCloseFacts(
            isListed: WindowBehaviorBundleList.contains(app.bundleIdentifier, in: preferences.quitOnCloseApps),
            isRegular: app.activationPolicy == .regular,
            isOwnProcess: pid == getpid(),
            isTerminated: app.isTerminated,
            isHidden: app.isHidden,
            hadWindow: true,
            accessibilityWindowCount: registry.liveWindows(for: pid).count,
            serverWindowCount: QuitOnCloseLogic.serverWindowCount(in: serverWindows, pid: pid)
        )
        guard QuitOnCloseLogic.shouldQuit(facts) else {
            // Something is still there: stop this round. The next close
            // starts a new one.
            rounds[pid] = nil
            return
        }
        guard isFinalLook else { return }

        hadWindow.remove(pid)
        hasWindowNow.remove(pid)
        rounds[pid] = nil
        // A normal quit request: unsaved-changes prompts still appear.
        app.terminate()
    }

    private func isListed(pid: pid_t) -> Bool {
        WindowBehaviorBundleList.contains(
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            in: preferences.quitOnCloseApps
        )
    }
}
