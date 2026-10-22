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
//  live in FocusAndWinTapLogic.swift (SpacesOrderPlan) and
//  FocusAndSpacesSafetyLogic.swift (SpacesOrderRunner, DockRestartPlan).
//
//  Order of writes, so a crash at any point can be finished or undone on the
//  next launch: the journal (what to put back, and a pending phase) is saved
//  and confirmed first; only then is the Dock preference written and read
//  back; only then is the journal marked held (or, on release, cleared). A
//  failure never turns the user's switch off: it is shown in Settings and
//  tried again a few times, further apart each time. A Dock restart is
//  recorded with the Dock's process IDs, so a later launch restarts the Dock
//  only when that same Dock is still running, and only a few times in all.
//

import AppKit
import Foundation
import Observation

@Observable
final class SpacesOrderService {
    static let shared = SpacesOrderService()

    // What Settings shows.

    /// Whether Wharf may write the Dock's value at all.
    private(set) var availability: SpacesOrderAvailability = .available
    /// The last change that did not take, while it is being retried.
    private(set) var lastFailure: SpacesOrderFailure?
    /// The retries ran out; the next launch, Dock start or toggle tries again.
    private(set) var retriesExhausted = false
    /// The switch is off but the old value is not back yet (journal kept).
    private(set) var restorePending = false
    /// The Dock did not restart after several attempts.
    private(set) var dockRestartGaveUp = false

    @ObservationIgnored private let preferences = BehaviorExtrasPreferences.shared
    @ObservationIgnored private static let domain = SpacesOrderPlan.dockDomain as CFString
    @ObservationIgnored private static let key = SpacesOrderPlan.preferenceKey as CFString
    @ObservationIgnored private static let systemSettingsBundleID = "com.apple.systempreferences"
    /// How long after a restart the Dock is checked for a new process.
    @ObservationIgnored private static let restartCheckDelay: TimeInterval = 5

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var restartedDuringApply = false

    private init() {}

    func start() {
        observePreference()
        observeExternalChanges()
        // Decide about a restart recorded by an earlier run before `apply`,
        // which may record a new one.
        let owed = launchRestartDecision()
        switch owed {
        case .clear:
            clearRestartRecord()
        case .giveUp:
            giveUpRestart()
        case .nothing, .restart:
            break
        }
        restartedDuringApply = false
        apply()
        if owed == .restart, !restartedDuringApply {
            // The last run changed the preference and the Dock it asked to
            // quit is still the one running, so it may still use the old value.
            restartDock()
        }
    }

    /// Reads the Dock's value again for Settings, which calls this when the
    /// section appears. Also runs on every `apply`.
    func refreshStatus() {
        CFPreferencesAppSynchronize(Self.domain)
        availability = SpacesOrderAvailability.from(
            raw: CFPreferencesCopyAppValue(Self.key, Self.domain),
            isForced: CFPreferencesAppValueIsForced(Self.key, Self.domain))
        restorePending = !preferences.spacesOrderFixed && preferences.spacesOrderJournal != nil
    }

    private func observePreference() {
        withObservationTracking {
            _ = preferences.spacesOrderFixed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Registered again before `apply`, so a change `apply` makes
                // itself (letting go) runs the step again too.
                self.observePreference()
                // A toggle is a fresh start for the retries.
                self.retryAttempt = 0
                self.retriesExhausted = false
                self.apply()
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
            self.clearRestartRecord()
            self.retryAttempt = 0
            self.retriesExhausted = false
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
            isForced: CFPreferencesAppValueIsForced(Self.key, Self.domain)
        )
    }

    private var runner: SpacesOrderRunner {
        SpacesOrderRunner(
            journal: { [preferences] in preferences.spacesOrderJournal },
            saveJournal: { [weak self] in self?.saveJournal($0) ?? false },
            current: { [weak self] in self?.currentSetting() ?? .unsupported },
            writeDock: { [weak self] in self?.writeDock($0) ?? false },
            restartDock: { [weak self] in self?.restartDock() }
        )
    }

    /// Brings the Dock preference in line with the switch. Runs at launch too,
    /// which is how a change the user made in System Settings while Wharf was
    /// quit, or a change cut off by a crash, gets noticed.
    private func apply() {
        retryWork?.cancel()
        retryWork = nil
        let outcome = runner.run(wanted: preferences.spacesOrderFixed)
        switch outcome {
        case .done:
            lastFailure = nil
            retryAttempt = 0
            retriesExhausted = false
        case .letGo:
            // Their choice stands; the switch follows it. The observation
            // runs `apply` once more, which then finds nothing to do.
            lastFailure = nil
            preferences.spacesOrderFixed = false
        case let .failed(failure):
            // The user's choice is kept as it is: no silent switch flip.
            lastFailure = failure
            NSLog("[Wharf] Fixed Space order: \(failure); keeping the setting and trying again later.")
            scheduleRetry()
        }
        refreshStatus()
    }

    private func scheduleRetry() {
        retryAttempt += 1
        guard let delay = SpacesOrderRetryPolicy.delay(forAttempt: retryAttempt) else {
            retriesExhausted = true
            NSLog("[Wharf] Fixed Space order: retries used up; trying again at the next launch, Dock start or toggle.")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Saves the journal in Wharf's defaults and confirms it. The signal is
    /// the result of CFPreferencesAppSynchronize (cfprefsd accepted the
    /// write; it puts it on disk itself), plus a read of both keys back
    /// through CFPreferences to check the values under the right keys. This
    /// proves the preferences daemon has the record, not that the file on
    /// disk was written yet. False when either check fails.
    private func saveJournal(_ journal: SpacesOrderJournal?) -> Bool {
        preferences.spacesOrderJournal = journal
        let app = kCFPreferencesCurrentApplication
        guard CFPreferencesAppSynchronize(app) else { return false }
        typealias Keys = BehaviorExtrasPreferences.Keys
        let restore = CFPreferencesCopyAppValue(Keys.spacesOrderRestoreMarker as CFString, app) as? String
        let phase = CFPreferencesCopyAppValue(Keys.spacesOrderPhase as CFString, app) as? String
        guard let journal else { return restore == nil && phase == nil }
        return restore == journal.restore && phase == journal.phase.rawValue
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

    // MARK: - Dock restart

    private func launchRestartDecision() -> DockRestartDecision {
        DockRestartPlan.decide(
            pending: preferences.spacesOrderDockRestartPending,
            recorded: preferences.spacesOrderDockRestartDocks,
            running: DockRestartGate.runningDockIdentities(),
            savedBootSession: preferences.spacesOrderDockRestartBootSession,
            currentBootSession: DockRestartGate.bootSessionID(),
            attempts: preferences.spacesOrderDockRestartAttempts)
    }

    /// Restarts the Dock so it reads the new value, through the gate shared
    /// with SystemDockVisibilityService. The record (pending, process IDs,
    /// time, attempts) is saved before the Dock is asked to quit; the Dock's
    /// launch notification, or a new process seen a few seconds later,
    /// clears it.
    private func restartDock() {
        restartedDuringApply = true
        preferences.spacesOrderDockRestartPending = true
        preferences.spacesOrderDockRestartDocks = Set(DockRestartGate.runningDockIdentities().compactMap { $0 })
        preferences.spacesOrderDockRestartBootSession = DockRestartGate.bootSessionID()
        preferences.spacesOrderDockRestartAttempts += 1
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        switch DockRestartGate.shared.restart(reason: "Fixed Space order") {
        case .notRunning:
            // Not running: it reads the preference when it next starts.
            clearRestartRecord()
            return
        case .joined:
            // Rode on a restart already under way: it cost no attempt.
            preferences.spacesOrderDockRestartAttempts -= 1
        case .submitted:
            break
        case .refused:
            // The record stays; the check below finds the same Dock and
            // tries again, a few times in all.
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartCheckDelay) { [weak self] in
            guard let self else { return }
            switch self.launchRestartDecision() {
            case .nothing:
                break
            case .clear:
                self.clearRestartRecord()
            case .restart:
                self.restartDock()
            case .giveUp:
                self.giveUpRestart()
            }
        }
    }

    private func clearRestartRecord() {
        preferences.spacesOrderDockRestartPending = false
        preferences.spacesOrderDockRestartDocks = []
        preferences.spacesOrderDockRestartBootSession = nil
        preferences.spacesOrderDockRestartAttempts = 0
        dockRestartGaveUp = false
    }

    private func giveUpRestart() {
        NSLog("[Wharf] Fixed Space order: the Dock did not restart after \(preferences.spacesOrderDockRestartAttempts) attempts; it picks up the change when it next starts.")
        clearRestartRecord()
        dockRestartGaveUp = true
    }
}
