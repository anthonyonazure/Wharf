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
        static let winTapAction = "wharf.windowsKeyboardWinTap.action"
    }

    enum DefaultValues {
        static let focusFollowsMouseEnabled = false
        static let focusFollowsMouseDelay = FocusFollowsMouseTiming.defaultDelayMilliseconds
        /// Off for every display until the user ticks one.
        static let focusFollowsMouseDisplays: [String] = []
        static let focusFollowsMouseExcluded: [String] = []
        static let spacesOrderFixed = false
        static let winTapAction = WinKeyTapAction.off
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var focusFollowsMouseEnabled: Bool {
        didSet { defaults.set(focusFollowsMouseEnabled, forKey: Keys.focusFollowsMouseEnabled) }
    }

    /// Clamped to `FocusFollowsMouseTiming.delayRange` on read and write.
    var focusFollowsMouseDelay: Int {
        didSet {
            let clamped = FocusFollowsMouseTiming.clampedDelay(focusFollowsMouseDelay)
            if clamped != focusFollowsMouseDelay {
                focusFollowsMouseDelay = clamped
                return
            }
            defaults.set(focusFollowsMouseDelay, forKey: Keys.focusFollowsMouseDelay)
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

    /// Read and written only by SpacesOrderService; not observed.
    @ObservationIgnored var spacesOrderRestoreMarker: String? {
        get { defaults.string(forKey: Keys.spacesOrderRestoreMarker) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.spacesOrderRestoreMarker)
            } else {
                defaults.removeObject(forKey: Keys.spacesOrderRestoreMarker)
            }
        }
    }

    private init() {
        focusFollowsMouseEnabled = defaults.object(forKey: Keys.focusFollowsMouseEnabled) as? Bool
            ?? DefaultValues.focusFollowsMouseEnabled
        focusFollowsMouseDelay = FocusFollowsMouseTiming.clampedDelay(
            defaults.object(forKey: Keys.focusFollowsMouseDelay) as? Int ?? DefaultValues.focusFollowsMouseDelay)
        focusFollowsMouseDisplays = defaults.stringArray(forKey: Keys.focusFollowsMouseDisplays)
            ?? DefaultValues.focusFollowsMouseDisplays
        focusFollowsMouseExcludedBundleIDs = defaults.stringArray(forKey: Keys.focusFollowsMouseExcluded)
            ?? DefaultValues.focusFollowsMouseExcluded
        spacesOrderFixed = defaults.object(forKey: Keys.spacesOrderFixed) as? Bool
            ?? DefaultValues.spacesOrderFixed
        winTapAction = defaults.string(forKey: Keys.winTapAction).flatMap(WinKeyTapAction.init(rawValue:))
            ?? DefaultValues.winTapAction
    }
}
