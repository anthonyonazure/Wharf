//
//  DockContext.swift
//  Wharf
//
//  Per-dock state. Wharf runs a dock on every display, so anything that
//  describes "this dock" rather than "the dock" lives here instead of in a
//  process-wide singleton.
//
//  Upstream Docky could keep layout and magnification as singletons because
//  only one dock existed. With three on screen they would share one set of
//  chrome measurements and one magnification ramp, so hovering a tile on one
//  monitor would visibly swell tiles on the other two.
//

import AppKit
import Combine

final class DockContext: ObservableObject {
    /// The display this dock belongs to, or nil in the single-window modes
    /// where the dock is not bound to a particular screen.
    @Published var displayID: CGDirectDisplayID?

    /// Chrome measurements for this dock alone.
    let layout = DockLayoutService()

    /// Magnification ramp for this dock alone, so a pointer on one screen
    /// cannot magnify tiles on another.
    let magnification = DockMagnificationService()

    private var cancellables: Set<AnyCancellable> = []

    init(displayID: CGDirectDisplayID? = nil) {
        self.displayID = displayID

        // SwiftUI does not observe through a nested ObservableObject, so a
        // view holding the context would never redraw on a layout change.
        // Re-emit the child's notification as our own.
        layout.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The screen this dock is on. Falls back to the screen the pointer is
    /// over for unbound docks, matching the legacy single-window behavior.
    var screen: NSScreen? {
        if let displayID {
            return NSScreen.screens.first { $0.displayID == displayID }
        }
        return NSScreen.main
    }
}
