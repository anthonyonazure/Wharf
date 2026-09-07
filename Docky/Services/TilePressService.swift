//
//  TilePressService.swift
//  Docky
//
//  Wharf: the dock's mouse. Every press, drag and release on a tile is
//  read here, from one AppKit event monitor, instead of from SwiftUI
//  gestures.
//
//  The reason is measured, not theoretical. Activation used to be an
//  `onTapGesture` nested inside the container's reorder `DragGesture`.
//  SwiftUI arbitrates between the two on every press and loses about half
//  of them, and the drag's event-tracking loop swallowed some releases
//  before any gesture could see them. Nothing built on that pair can be
//  reliable, so tiles that are a single click target no longer carry
//  either gesture: this monitor identifies the tile by hit-testing the
//  press against the frames the container publishes, and calls the
//  tile's action directly on release.
//
//  A local monitor returns the event unchanged, so ordinary dispatch
//  still happens: right-click menus, text fields and the controls inside
//  widget tiles are untouched. A global monitor covers the release when
//  the pointer has left the dock's own window mid-drag.
//

import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class TilePressService: ObservableObject {
    static let shared = TilePressService()
    private static let logger = Logger(subsystem: "gt.quintero.Wharf", category: "TilePress")

    /// AppKit's own drag slop. Below this a press is a click; a mouse
    /// drifts a few points between press and release and that must not
    /// turn into a reorder.
    private static let dragSlop: CGFloat = 10

    @Published private(set) var pressedTileID: String?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoveredTileID: String?

    private struct Press {
        let tileID: String
        let surface: NSView
        let startPoint: CGPoint
        var isDragging = false
        var lastPoint: CGPoint
    }

    private var press: Press?

    private init() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        // Releases and drags that land outside the dock window still have
        // to finish the gesture — dragging a tile off the dock is how you
        // remove it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }

    /// Called from `TileView.onHover`. Hover no longer decides what a
    /// click acts on — it lags the pointer, and acting on the icon the
    /// cursor just passed is worse than doing nothing — but it still
    /// drives the pressed-tile highlight for tiles the router does not
    /// own, such as widgets.
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
        if press?.tileID == tileID {
            press = nil
        }
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginPress(event)
        case .leftMouseDragged:
            continuePress(event)
        case .leftMouseUp:
            endPress(event)
        default:
            break
        }
    }

    private func beginPress(_ event: NSEvent) {
        // A press always supersedes whatever the last one left behind.
        // Releases can still be lost to a menu or a modal tracking loop,
        // and stale press state would then act on the wrong tile.
        press = nil

        guard let surface = surface(for: event),
              let point = location(of: event, in: surface),
              let tileID = TileClickRouter.shared.tileID(at: point, in: surface),
              TileClickRouter.shared.hasClickHandler(tileID: tileID, in: surface) else {
            pressedTileID = hoveredTileID
            return
        }

        press = Press(tileID: tileID, surface: surface, startPoint: point, lastPoint: point)
        pressedTileID = tileID
        Self.logger.info("press began tile=\(tileID, privacy: .public) clickCount=\(event.clickCount, privacy: .public)")
    }

    private func continuePress(_ event: NSEvent) {
        guard var current = press else { return }
        guard let point = location(of: event, in: current.surface) else { return }

        current.lastPoint = point
        let translation = CGSize(
            width: point.x - current.startPoint.x,
            height: point.y - current.startPoint.y
        )

        if !current.isDragging {
            guard hypot(translation.width, translation.height) >= Self.dragSlop else {
                press = current
                return
            }
            guard let callbacks = TileClickRouter.shared.dragCallbacks(in: current.surface),
                  callbacks.isDraggable(current.tileID) else {
                press = current
                return
            }
            current.isDragging = true
            pressedTileID = nil
        }

        press = current
        TileClickRouter.shared.dragCallbacks(in: current.surface)?
            .update(current.tileID, point, translation)
    }

    private func endPress(_ event: NSEvent) {
        guard let current = press else {
            pressedTileID = nil
            return
        }
        press = nil
        pressedTileID = nil

        let point = location(of: event, in: current.surface) ?? current.lastPoint
        let translation = CGSize(
            width: point.x - current.startPoint.x,
            height: point.y - current.startPoint.y
        )

        if current.isDragging {
            TileClickRouter.shared.dragCallbacks(in: current.surface)?
                .end(current.tileID, point, translation)
            return
        }

        // The tile has to still be under the pointer. Pressing an icon,
        // sliding off it and releasing is a cancelled click everywhere
        // else on the system.
        guard TileClickRouter.shared.tileID(at: point, in: current.surface) == current.tileID else {
            Self.logger.info("press cancelled off-tile tile=\(current.tileID, privacy: .public)")
            return
        }

        Self.logger.info("click tile=\(current.tileID, privacy: .public)")
        TileClickRouter.shared.performClick(tileID: current.tileID, in: current.surface)
    }

    // MARK: - Geometry

    private func surface(for event: NSEvent) -> NSView? {
        (event.window as? MainWindow)?.dockHostingView
    }

    /// Converts an event into the space the tile frames were measured in:
    /// the hosting view's own bounds, origin top-left, which is what
    /// SwiftUI calls `.global`. Converting through the view rather than
    /// the window means the dock's content insets cannot skew the result.
    private func location(of event: NSEvent, in view: NSView) -> CGPoint? {
        guard let window = view.window else { return nil }
        let windowPoint: CGPoint
        if event.window === window {
            windowPoint = event.locationInWindow
        } else {
            windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        }
        let local = view.convert(windowPoint, from: nil)
        guard view.isFlipped else {
            return CGPoint(x: local.x, y: view.bounds.height - local.y)
        }
        return local
    }
}
