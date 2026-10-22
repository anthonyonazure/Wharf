//
//  DockContext+PerScreen.swift
//  Wharf
//
//  The one place a dock asks "what are my settings?". Each answer is this
//  display's override when it has one, otherwise the global setting, so the
//  window frame and every view inside it agree on edge, size and hiding.
//
//  Unbound docks (the single window Display modes) have no display ID and
//  always get the global values.
//

import AppKit

extension DockContext {
    /// The edge this dock sits on.
    var resolvedPosition: ResolvedDockWindowPosition {
        PerScreenResolution.position(
            override: PerDisplaySettings.shared.override(for: displayID)?.position,
            global: DockyPreferences.shared.windowPosition
        )
        .resolved(systemOrientation: DockSettingsService.shared.orientation)
    }

    /// Base tile size for this dock, before overflow scaling.
    var resolvedTileSize: CGFloat {
        CGFloat(PerScreenResolution.tileSize(
            override: PerDisplaySettings.shared.tileSize(for: displayID).map(Double.init),
            global: Double(DockSettingsService.shared.displayTileSize)
        ))
    }

    /// Whether this dock hides until the pointer reaches its edge.
    var resolvedAutohides: Bool {
        PerScreenResolution.autohide(
            override: PerDisplaySettings.shared.autohide(for: displayID),
            global: DockyPreferences.shared.autohidesWindow
        )
    }

    /// The edge setting this dock follows (before "System" is resolved), for
    /// the checkmark in its own Position menu.
    var effectivePositionSetting: DockWindowPosition {
        PerDisplaySettings.shared.position(for: displayID) ?? DockyPreferences.shared.windowPosition
    }

    /// Changes this dock's edge from its own menu: its display override when
    /// it has one, otherwise the global setting it inherits.
    func setPosition(_ position: DockWindowPosition) {
        let settings = PerDisplaySettings.shared
        if let displayID,
           let updated = PerScreenResolution.settingPosition(position.rawValue, in: settings.override(for: displayID)) {
            settings.setOverride(updated, for: displayID)
        } else {
            DockyPreferences.shared.windowPosition = position
        }
    }

    /// Changes this dock's hiding from its own menu, by the same rule.
    func setAutohides(_ autohides: Bool) {
        let settings = PerDisplaySettings.shared
        if let displayID,
           let updated = PerScreenResolution.settingAutohide(autohides, in: settings.override(for: displayID)) {
            settings.setOverride(updated, for: displayID)
        } else {
            DockyPreferences.shared.autohidesWindow = autohides
        }
    }
}
