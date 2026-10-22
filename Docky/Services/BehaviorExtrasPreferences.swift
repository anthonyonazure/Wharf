//
//  BehaviorExtrasPreferences.swift
//  Wharf
//
//  Preferences for focus follows mouse, fixed Space order and the Win key
//  tap. Kept in their own store, the way PerDisplaySettings is, rather than
//  in DockyPreferences, so these features add a file instead of editing the
//  shared one. Every key starts with its feature's prefix.
//

import Foundation
import Observation

@Observable
final class BehaviorExtrasPreferences {
    static let shared = BehaviorExtrasPreferences()

    enum Keys {
        static let focusFollowsMouseEnabled = "wharf.focusFollowsMouse.enabled"
        static let focusFollowsMouseDelay = "wharf.focusFollowsMouse.delayMilliseconds"
        static let focusFollowsMouseDisplays = "wharf.focusFollowsMouse.displayUUIDs"
        static let focusFollowsMouseExcluded = "wharf.focusFollowsMouse.excludedBundleIDs"
        static let spacesOrderFixed = "wharf.spacesOrder.fixed"
        /// What `mru-spaces` read before Wharf changed it: "absent", "on" or
        /// "off". Present only while Wharf holds the order fixed.
        static let spacesOrderRestoreMarker = "wharf.spacesOrder.restoreMarker"
        /// How far the change got (`SpacesHoldPhase`). Missing on a marker
        /// saved by an earlier build, which only saved it once held.
        static let spacesOrderPhase = "wharf.spacesOrder.phase"
        /// Set before Wharf restarts the Dock, cleared once it is back.
        static let spacesOrderDockRestartPending = "wharf.spacesOrder.dockRestartPending"
        /// The Dock process IDs Wharf asked to quit, when it asked, and how
        /// many restarts this change has cost so far (across launches), so a
        /// later launch compares instead of restarting the Dock blindly.
        static let spacesOrderDockRestartPIDs = "wharf.spacesOrder.dockRestartPIDs"
        static let spacesOrderDockRestartRequestedAt = "wharf.spacesOrder.dockRestartRequestedAt"
        static let spacesOrderDockRestartAttempts = "wharf.spacesOrder.dockRestartAttempts"
        static let winTapAction = "wharf.windowsKeyboardWinTap.action"
        static let snipInExcludedApps = "wharf.windowsKeyboardSnip.inExcludedApps"
    }

    enum DefaultValues {
        static let focusFollowsMouseEnabled = false
        static let focusFollowsMouseDelay = FocusFollowsMouseTiming.defaultDelayMilliseconds
        /// Off for every display until the user ticks one.
        static let focusFollowsMouseDisplays: [String] = []
        static let focusFollowsMouseExcluded: [String] = []
        static let spacesOrderFixed = false
        static let winTapAction = WinKeyTapAction.off
        /// Excluded apps (remote desktops, virtual machines) keep Win+Shift+S.
        static let snipInExcludedApps = false
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var focusFollowsMouseEnabled: Bool {
        didSet { defaults.set(focusFollowsMouseEnabled, forKey: Keys.focusFollowsMouseEnabled) }
    }

    /// Clamped to `FocusFollowsMouseTiming.delayRange` on read and write.
    var focusFollowsMouseDelay: Int {
        didSet {
            // The clamped value is what gets saved, whether or not the
            // reassignment below runs this observer again.
            let clamped = FocusFollowsMouseTiming.clampedDelay(focusFollowsMouseDelay)
            defaults.set(clamped, forKey: Keys.focusFollowsMouseDelay)
            if clamped != focusFollowsMouseDelay { focusFollowsMouseDelay = clamped }
        }
    }

    /// Persistent display UUIDs (`PerDisplaySettings.key(for:)`) where hover
    /// focus is on. UUIDs survive reboots and cable swaps; display IDs do not.
    var focusFollowsMouseDisplays: [String] {
        didSet { defaults.set(focusFollowsMouseDisplays, forKey: Keys.focusFollowsMouseDisplays) }
    }

    var focusFollowsMouseExcludedBundleIDs: [String] {
        didSet { defaults.set(focusFollowsMouseExcludedBundleIDs, forKey: Keys.focusFollowsMouseExcluded) }
    }

    var spacesOrderFixed: Bool {
        didSet { defaults.set(spacesOrderFixed, forKey: Keys.spacesOrderFixed) }
    }

    var winTapAction: WinKeyTapAction {
        didSet { defaults.set(winTapAction.rawValue, forKey: Keys.winTapAction) }
    }

    var snipInExcludedApps: Bool {
        didSet { defaults.set(snipInExcludedApps, forKey: Keys.snipInExcludedApps) }
    }

    /// Read and written only by SpacesOrderService; not observed. Setting
    /// it writes both keys; callers flush and read back before relying on it.
    @ObservationIgnored var spacesOrderJournal: SpacesOrderJournal? {
        get {
            guard let restore = defaults.string(forKey: Keys.spacesOrderRestoreMarker) else { return nil }
            let phase = defaults.string(forKey: Keys.spacesOrderPhase).flatMap(SpacesHoldPhase.init(rawValue:)) ?? .held
            return SpacesOrderJournal(restore: restore, phase: phase)
        }
        // Phase written before the marker and removed after it, so a crash
        // between the two reads back as the whole record or as none, never
        // as a marker with the phase missing (which reads as held).
        set {
            if let newValue {
                defaults.set(newValue.phase.rawValue, forKey: Keys.spacesOrderPhase)
                defaults.set(newValue.restore, forKey: Keys.spacesOrderRestoreMarker)
            } else {
                defaults.removeObject(forKey: Keys.spacesOrderRestoreMarker)
                defaults.removeObject(forKey: Keys.spacesOrderPhase)
            }
        }
    }

    @ObservationIgnored var spacesOrderDockRestartPending: Bool {
        get { defaults.bool(forKey: Keys.spacesOrderDockRestartPending) }
        set { defaults.set(newValue, forKey: Keys.spacesOrderDockRestartPending) }
    }

    @ObservationIgnored var spacesOrderDockRestartPIDs: Set<pid_t> {
        get { Set((defaults.array(forKey: Keys.spacesOrderDockRestartPIDs) as? [Int] ?? []).map { pid_t($0) }) }
        set { defaults.set(newValue.map { Int($0) }.sorted(), forKey: Keys.spacesOrderDockRestartPIDs) }
    }

    /// Seconds since 1970, or nil when no restart is recorded.
    @ObservationIgnored var spacesOrderDockRestartRequestedAt: Date? {
        get { (defaults.object(forKey: Keys.spacesOrderDockRestartRequestedAt) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Keys.spacesOrderDockRestartRequestedAt)
            } else {
                defaults.removeObject(forKey: Keys.spacesOrderDockRestartRequestedAt)
            }
        }
    }

    @ObservationIgnored var spacesOrderDockRestartAttempts: Int {
        get { defaults.integer(forKey: Keys.spacesOrderDockRestartAttempts) }
        set { defaults.set(newValue, forKey: Keys.spacesOrderDockRestartAttempts) }
    }

    /// Back to defaults, for Reset Behavior and the full reset. Fixed Space
    /// order goes first and leaves the journal alone: SpacesOrderService sees
    /// the switch go off and puts the Dock preference back through its usual
    /// release, clearing the journal only once that worked. The other
    /// services see their switches go off and uninstall.
    func resetToDefaults() {
        spacesOrderFixed = DefaultValues.spacesOrderFixed
        focusFollowsMouseEnabled = DefaultValues.focusFollowsMouseEnabled
        focusFollowsMouseDelay = DefaultValues.focusFollowsMouseDelay
        focusFollowsMouseDisplays = DefaultValues.focusFollowsMouseDisplays
        focusFollowsMouseExcludedBundleIDs = DefaultValues.focusFollowsMouseExcluded
        winTapAction = DefaultValues.winTapAction
        snipInExcludedApps = DefaultValues.snipInExcludedApps
    }

    private init() {
        focusFollowsMouseEnabled = defaults.object(forKey: Keys.focusFollowsMouseEnabled) as? Bool
            ?? DefaultValues.focusFollowsMouseEnabled
        let storedDelay = FocusFollowsMouseTiming.storedDelay(defaults.object(forKey: Keys.focusFollowsMouseDelay))
        focusFollowsMouseDelay = storedDelay.value
        // Observers do not run in init, so a bad stored value is fixed here.
        if storedDelay.needsRewrite { defaults.set(storedDelay.value, forKey: Keys.focusFollowsMouseDelay) }
        focusFollowsMouseDisplays = defaults.stringArray(forKey: Keys.focusFollowsMouseDisplays)
            ?? DefaultValues.focusFollowsMouseDisplays
        focusFollowsMouseExcludedBundleIDs = BundleIDList.deduplicated(
            defaults.stringArray(forKey: Keys.focusFollowsMouseExcluded) ?? DefaultValues.focusFollowsMouseExcluded)
        spacesOrderFixed = defaults.object(forKey: Keys.spacesOrderFixed) as? Bool
            ?? DefaultValues.spacesOrderFixed
        winTapAction = defaults.string(forKey: Keys.winTapAction).flatMap(WinKeyTapAction.init(rawValue:))
            ?? DefaultValues.winTapAction
        snipInExcludedApps = defaults.object(forKey: Keys.snipInExcludedApps) as? Bool
            ?? DefaultValues.snipInExcludedApps
    }
}
