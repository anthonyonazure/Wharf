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
//  GPL-3.0), without its Dock restart journal. The decisions live in
//  FocusAndWinTapLogic.swift (SpacesOrderPlan).
//

import AppKit
import Foundation

final class SpacesOrderService {
    static let shared = SpacesOrderService()

    private let preferences = BehaviorExtrasPreferences.shared
    private static let domain = SpacesOrderPlan.dockDomain as CFString
    private static let key = SpacesOrderPlan.preferenceKey as CFString

    private init() {}

    func start() {
        observePreference()
        apply()
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

    private func currentSetting() -> SpacesRearrangeSetting {
        CFPreferencesAppSynchronize(Self.domain)
        return SpacesRearrangeSetting.from(
            raw: CFPreferencesCopyAppValue(Self.key, Self.domain),
            isForced: isManaged
        )
    }

    /// Brings the Dock preference in line with the switch. Runs at launch too,
    /// which is how a change the user made in System Settings while Wharf was
    /// quit gets noticed.
    private func apply() {
        let step = SpacesOrderPlan.step(
            wanted: preferences.spacesOrderFixed,
            current: currentSetting(),
            marker: preferences.spacesOrderRestoreMarker
        )
        switch step {
        case .none:
            break
        case let .hold(marker):
            // Saved first, so a crash between the two still knows what to restore.
            preferences.spacesOrderRestoreMarker = marker
            write(false)
        case .remember:
            preferences.spacesOrderRestoreMarker = SpacesOrderPlan.restoreOff
        case let .release(removeKey):
            write(removeKey ? nil : true)
            preferences.spacesOrderRestoreMarker = nil
        case .forget:
            preferences.spacesOrderRestoreMarker = nil
        case .letGo:
            preferences.spacesOrderRestoreMarker = nil
            preferences.spacesOrderFixed = false
        }
    }

    /// Writes `mru-spaces` (nil removes the key, the system default) and
    /// restarts the Dock so it reads the new value, the same way
    /// SystemDockVisibilityService applies its Dock changes. The system
    /// starts the Dock again at once.
    private func write(_ value: Bool?) {
        CFPreferencesSetAppValue(Self.key, value.map { $0 as CFBoolean }, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        NSRunningApplication
            .runningApplications(withBundleIdentifier: SpacesOrderPlan.dockDomain)
            .forEach { $0.forceTerminate() }
    }
}
