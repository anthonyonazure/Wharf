//
//  SpacesOrderService.swift
//  Wharf
//
//  Fixed Space order: stops macOS from rearranging Spaces by most recent use
//  by setting the Dock's `mru-spaces` preference to false, the same switch as
//  "Automatically rearrange Spaces based on most recent use" in System
//  Settings. What the preference read before is saved in Wharf's defaults and
//  put back when the feature is turned off.
//
//  Adapted from Vorssaint's SpacesOrderHold (vorssaint/vorssaint-utils,
//  GPL-3.0), including the idea of its Dock restart journal. The decisions
//  live in FocusAndWinTapLogic.swift (SpacesOrderPlan).
//
//  Order of writes, so a crash at any point can be finished or undone on the
//  next launch: the journal (what to put back, and a pending phase) is saved,
//  flushed to disk and read back first; only then is the Dock preference
//  written, flushed and read back; only then is the journal marked held (or,
//  on release, cleared). A Dock restart is recorded before it is attempted
//  and cleared only when the Dock is seen launching again.
//

import AppKit
import Foundation

final class SpacesOrderService {
    static let shared = SpacesOrderService()

    private let preferences = BehaviorExtrasPreferences.shared
    private static let domain = SpacesOrderPlan.dockDomain as CFString
    private static let key = SpacesOrderPlan.preferenceKey as CFString
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let maximumRestartAttempts = 3

    private var restartAttempts = 0
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        observePreference()
        observeExternalChanges()
        apply()
        if preferences.spacesOrderDockRestartPending {
            // The last run changed the preference but never saw the Dock
            // come back, so it may still be using the old value.
            restartDock()
        }
    }

    /// True when a management profile forces the preference, so Wharf
    /// cannot change it. The settings switch says so.
    var isManaged: Bool {
        CFPreferencesAppValueIsForced(Self.key, Self.domain)
    }

    private func observePreference() {
        withObservationTracking {
            _ = preferences.spacesOrderFixed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.apply()
                self?.observePreference()
            }
        }
    }

    /// No notification announces a change to another app's preferences, so
    /// look again whenever someone may have made one: when System Settings
    /// is left or quit, and when the Dock starts (which is also how a
    /// restart Wharf asked for is confirmed).
    private func observeExternalChanges() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, Self.bundleID(in: note) == SpacesOrderPlan.dockDomain else { return }
            self.preferences.spacesOrderDockRestartPending = false
            self.restartAttempts = 0
            self.apply()
        })
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, Self.bundleID(in: note) == Self.systemSettingsBundleID else { return }
                self.apply()
            })
        }
    }

    private static func bundleID(in note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func currentSetting() -> SpacesRearrangeSetting {
        CFPreferencesAppSynchronize(Self.domain)
        return SpacesRearrangeSetting.from(
            raw: CFPreferencesCopyAppValue(Self.key, Self.domain),
            isForced: isManaged
        )
    }

    /// Brings the Dock preference in line with the switch. Runs at launch too,
    /// which is how a change the user made in System Settings while Wharf was
    /// quit, or a change cut off by a crash, gets noticed.
    private func apply() {
        let step = SpacesOrderPlan.step(
            wanted: preferences.spacesOrderFixed,
            current: currentSetting(),
            journal: preferences.spacesOrderJournal
        )
        switch step {
        case .none:
            break
        case let .hold(restore):
            hold(restore: restore)
        case .confirmHold:
            if let journal = preferences.spacesOrderJournal {
                saveJournal(SpacesOrderJournal(restore: journal.restore, phase: .held))
            }
        case .remember:
            saveJournal(SpacesOrderJournal(restore: SpacesOrderPlan.restoreOff, phase: .held))
        case let .release(removeKey):
            release(removeKey: removeKey)
        case .forget:
            saveJournal(nil)
        case .letGo:
            // Their choice stands; the switch follows it.
            saveJournal(nil)
            preferences.spacesOrderFixed = false
        }
    }

    private func hold(restore: String) {
        guard saveJournal(SpacesOrderJournal(restore: restore, phase: .pendingHold)) else {
            // Without a durable record of what to put back, the Dock is not
            // touched at all.
            NSLog("[Wharf] Fixed Space order: could not save the restore record; leaving the Dock alone.")
            preferences.spacesOrderFixed = false
            return
        }
        guard writeDock(false) else {
            // Turning the switch off runs the step again: it puts the old
            // value back if the write half landed, or just forgets.
            NSLog("[Wharf] Fixed Space order: the Dock preference did not take; turning the feature off.")
            preferences.spacesOrderFixed = false
            return
        }
        saveJournal(SpacesOrderJournal(restore: restore, phase: .held))
        restartDock()
    }

    private func release(removeKey: Bool) {
        guard let journal = preferences.spacesOrderJournal else { return }
        saveJournal(SpacesOrderJournal(restore: journal.restore, phase: .pendingRelease))
        guard writeDock(removeKey ? nil : true) else {
            // The journal stays, so the next launch or the next toggle tries
            // again instead of losing what to put back.
            NSLog("[Wharf] Fixed Space order: restoring the Dock preference failed; will retry.")
            return
        }
        saveJournal(nil)
        restartDock()
    }

    /// Saves the journal in Wharf's defaults, flushes them to disk and reads
    /// the value back. False when any of that fails.
    @discardableResult
    private func saveJournal(_ journal: SpacesOrderJournal?) -> Bool {
        preferences.spacesOrderJournal = journal
        guard CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) else { return false }
        return preferences.spacesOrderJournal == journal
    }

    /// Writes `mru-spaces` (nil removes the key, the system default), flushes
    /// it and reads it back. False when the Dock domain does not read the
    /// value afterwards.
    private func writeDock(_ value: Bool?) -> Bool {
        CFPreferencesSetAppValue(Self.key, value.map { $0 as CFBoolean }, Self.domain)
        guard CFPreferencesAppSynchronize(Self.domain) else { return false }
        let expected: SpacesRearrangeSetting = value.map { $0 ? .on : .off } ?? .absent
        return currentSetting() == expected
    }

    /// Restarts the Dock so it reads the new value, the same way
    /// SystemDockVisibilityService applies its Dock changes. The system
    /// starts the Dock again at once; its launch notification clears the
    /// pending mark. A Dock that does not come back is retried a few times,
    /// then reported in the log and left for the next launch.
    private func restartDock() {
        preferences.spacesOrderDockRestartPending = true
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: SpacesOrderPlan.dockDomain)
        guard !docks.isEmpty else {
            // Not running: it reads the preference when it next starts.
            preferences.spacesOrderDockRestartPending = false
            return
        }
        restartAttempts += 1
        let oldPIDs = Set(docks.map(\.processIdentifier))
        if !docks.map({ $0.forceTerminate() }).contains(true) {
            NSLog("[Wharf] Fixed Space order: the Dock refused to quit (attempt \(restartAttempts)).")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.preferences.spacesOrderDockRestartPending else { return }
            // A Dock under a new process ID is a restarted Dock, whether or
            // not its launch notification arrived. Never restart it twice.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: SpacesOrderPlan.dockDomain)
            if running.contains(where: { !oldPIDs.contains($0.processIdentifier) }) {
                self.preferences.spacesOrderDockRestartPending = false
                self.restartAttempts = 0
                return
            }
            guard self.restartAttempts < Self.maximumRestartAttempts else {
                NSLog("[Wharf] Fixed Space order: the Dock did not restart after \(self.restartAttempts) attempts; it picks up the change when it next starts.")
                return
            }
            self.restartDock()
        }
    }
}
