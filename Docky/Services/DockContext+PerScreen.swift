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
}
