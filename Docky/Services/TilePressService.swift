//
//  TilePressService.swift
//  Docky
//
//  Tracks which dock tile is currently being pressed (mouse-down before
//  release) using a single NSEvent local monitor instead of a SwiftUI
//  gesture. The previous gesture-based tracker conflicted with the parent
//  reorder gesture and prevented tile drag; observing at the AppKit event
//  layer side-steps SwiftUI's gesture-claim contest entirely — local
//  monitors return the event unchanged so normal dispatch still happens.
//
//  Press identity is resolved via the tile's own `.onHover` state, not
//  by hit-testing stored frames. SwiftUI's hover already accounts for
//  `.scaleEffect` (magnification), so we always agree with the tile the
//  user visually sees under the cursor — manual hit-testing against the
//  unscaled layout frame would otherwise pick the next tile over when
//  the hovered tile's magnified edge spills past its layout bounds.
//

import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class TilePressService: ObservableObject {
    static let shared = TilePressService()
    private static let logger = Logger(subsystem: "gt.quintero.Wharf", category: "TilePress")

    @Published private(set) var pressedTileID: String?

    /// Fires once per click, naming the tile and the dock window it happened in.
    ///
    /// Wharf: the tile's click used to be SwiftUI's `onTapGesture`, and it
    /// dropped about half of them. Traced on a live desk: AppKit delivered
    /// eight mouse-downs to the dock window, this service identified the
    /// correct tile for all eight, and the tap gesture fired four times. It
    /// loses an arbitration with the container's reorder drag, and no
    /// threshold on that drag changes the outcome.
    ///
    /// Press and release are already watched here, which the header explains
    /// was done to escape exactly that contest. Emitting the click from here
    /// removes the recognizer from the path entirely.
    ///
    /// The window number matters: with a dock on every display the same tile
    /// exists three times over, and a tap naming only the tile ran the action
    /// once per dock, raise then hide then raise, which reads as a dead click.
    struct Tap {
        let tileID: String
        let windowNumber: Int
    }

    let taps = PassthroughSubject<Tap, Never>()

    /// How far the pointer may travel and still be a click. Matches the
    /// reorder drag's threshold in `TileContainerView`, so there is no band
    /// where a press is neither a click nor a drag.
    private static let clickSlop: CGFloat = 10

    private var monitor: Any?
    private var hoveredTileID: String?
    private var pressOrigin: NSPoint?
    private var pressWindowNumber: Int?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Called from `TileView.onHover`. The most recently entered tile is
    /// the one that "owns" the cursor for press purposes.
    func registerHover(tileID: String, isHovering: Bool) {
        if isHovering {
            hoveredTileID = tileID
        } else if hoveredTileID == tileID {
            hoveredTileID = nil
        }
    }

    func clearHover(tileID: String) {
        if hoveredTileID == tileID {
            hoveredTileID = nil
        }
        if pressedTileID == tileID {
            pressedTileID = nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            Self.logger.info("leftMouseDown hovered=\(self.hoveredTileID ?? "nil", privacy: .public) clickCount=\(event.clickCount, privacy: .public) modifiers=\(event.modifierFlags.rawValue, privacy: .public)")
            pressedTileID = hoveredTileID
            // The event's own location, not `NSEvent.mouseLocation`, which
            // reports where the cursor is now and lags a fast movement enough
            // to make a still click look like a long drag.
            pressOrigin = event.locationInWindow
            pressWindowNumber = event.windowNumber
        case .leftMouseUp:
            Self.logger.info("leftMouseUp pressedTileID=\(self.pressedTileID ?? "nil", privacy: .public) clickCount=\(event.clickCount, privacy: .public)")
            if let tileID = pressedTileID ?? hoveredTileID,
               hoveredTileID == tileID,
               let origin = pressOrigin,
               pressWindowNumber == event.windowNumber {
                let dx = event.locationInWindow.x - origin.x
                let dy = event.locationInWindow.y - origin.y
                if (dx * dx + dy * dy) < (Self.clickSlop * Self.clickSlop) {
                    taps.send(Tap(tileID: tileID, windowNumber: event.windowNumber))
                }
            }
            pressOrigin = nil
            pressWindowNumber = nil
            if pressedTileID != nil {
                pressedTileID = nil
            }
        default:
            break
        }
    }
}
