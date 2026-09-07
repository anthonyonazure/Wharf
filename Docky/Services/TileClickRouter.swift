//
//  TileClickRouter.swift
//  Docky
//
//  Wharf: the registry that lets an AppKit event monitor act on a tile
//  without going through a SwiftUI gesture.
//
//  Why this exists. A tile's activation used to be an `onTapGesture`
//  sitting inside the container's reorder `DragGesture`. SwiftUI has to
//  arbitrate between the two on every press, and it gets it wrong often
//  enough to be obvious: measured on a live dock, about half of the
//  releases that arrived lost the arbitration and the tap never ran, and
//  the drag's own event-tracking loop swallowed two of nineteen releases
//  outright. A click that is sometimes ignored is the single most visible
//  defect in a dock.
//
//  The fix is to stop asking SwiftUI to arbitrate. `TilePressService`
//  already watches mouse events at the AppKit layer, where nothing
//  competes for them. This type is what turns a raw point into a tile:
//  each dock's SwiftUI surface publishes its tile frames and its
//  per-tile action here, keyed by the hosting view they were measured in.
//
//  Keyed by the hosting view, not the window, on purpose. SwiftUI's
//  `.global` space starts at the top-left of the `NSHostingView`, which
//  the dock insets from the window edge by a user-adjustable amount. A
//  point converted against the window is therefore off by whatever the
//  content insets happen to be, which is why an earlier attempt at this
//  matched tiles correctly in one run and not the next. Converting
//  against the hosting view itself needs no assumption about chrome.
//  With one dock per display the key also keeps three identical sets of
//  tile IDs from overwriting each other.
//

import AppKit
import Foundation

@MainActor
final class TileClickRouter {
    static let shared = TileClickRouter()

    /// What the container needs to run a reorder drag when the drag is
    /// driven from AppKit instead of from a `DragGesture`. Points are in
    /// the same space as the published frames: hosting-view coordinates,
    /// origin top-left.
    struct DragCallbacks {
        let isDraggable: (String) -> Bool
        let update: (String, CGPoint, CGSize) -> Void
        let end: (String, CGPoint, CGSize) -> Void
    }

    private struct Surface {
        weak var view: NSView?
        var frames: [String: CGRect] = [:]
        var clicks: [String: () -> Void] = [:]
        var drag: DragCallbacks?

        var isEmpty: Bool {
            view == nil || (frames.isEmpty && clicks.isEmpty && drag == nil)
        }
    }

    private var surfaces: [ObjectIdentifier: Surface] = [:]

    private init() {}

    /// Whether a tile's whole surface is one click target, and so can be
    /// driven from the event monitor.
    ///
    /// Widget and smart-stack tiles are excluded because they hold their
    /// own controls — transport buttons, a join-meeting button, a text
    /// field. SwiftUI stops a tap at the control that handled it; an
    /// AppKit monitor cannot know that happened, so routing those would
    /// fire the tile's action on top of every button press inside it.
    /// They keep their SwiftUI gestures.
    static func routesClicks(_ tile: Tile) -> Bool {
        switch tile.content {
        case .app, .minimizedWindow, .appFolder, .launchpad, .startMenu, .folder, .trash:
            return true
        case .widget, .smartStack, .spacer, .flexibleSpacer, .divider:
            return false
        }
    }

    // MARK: - Registration

    func setFrames(_ frames: [String: CGRect], in view: NSView) {
        mutate(view) { $0.frames = frames }
    }

    func setDragCallbacks(_ callbacks: DragCallbacks?, in view: NSView) {
        mutate(view) { $0.drag = callbacks }
    }

    /// Registers the action a whole-surface tile performs when clicked.
    /// Only tiles that are a single target register here; widget tiles
    /// keep their SwiftUI taps because they contain their own controls,
    /// and firing both would double every button press inside them.
    func registerClick(tileID: String, in view: NSView, action: @escaping () -> Void) {
        mutate(view) { $0.clicks[tileID] = action }
    }

    func unregisterClick(tileID: String, in view: NSView) {
        mutate(view) { $0.clicks.removeValue(forKey: tileID) }
    }

    func forget(view: NSView) {
        surfaces.removeValue(forKey: ObjectIdentifier(view))
    }

    // MARK: - Lookup

    /// The tile under a point, or nil. Overlapping frames resolve to the
    /// nearest centre so a hover pop that spills past a tile's layout
    /// bounds cannot claim its neighbour's half of the gap.
    func tileID(at point: CGPoint, in view: NSView) -> String? {
        guard let surface = surfaces[ObjectIdentifier(view)] else { return nil }
        var best: (id: String, distance: CGFloat)?
        for (id, frame) in surface.frames where frame.contains(point) {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let distance = hypot(centre.x - point.x, centre.y - point.y)
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        return best?.id
    }

    func hasClickHandler(tileID: String, in view: NSView) -> Bool {
        surfaces[ObjectIdentifier(view)]?.clicks[tileID] != nil
    }

    @discardableResult
    func performClick(tileID: String, in view: NSView) -> Bool {
        guard let action = surfaces[ObjectIdentifier(view)]?.clicks[tileID] else { return false }
        action()
        return true
    }

    func dragCallbacks(in view: NSView) -> DragCallbacks? {
        surfaces[ObjectIdentifier(view)]?.drag
    }

    // MARK: - Internals

    private func mutate(_ view: NSView, _ body: (inout Surface) -> Void) {
        let key = ObjectIdentifier(view)
        var surface = surfaces[key] ?? Surface(view: view)
        surface.view = view
        body(&surface)
        if surface.isEmpty {
            surfaces.removeValue(forKey: key)
        } else {
            surfaces[key] = surface
        }
        surfaces = surfaces.filter { $0.value.view != nil }
    }
}
