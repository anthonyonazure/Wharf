//
//  WindowSnapDragService.swift
//  Wharf
//
//  Drag triggers for window snapping. Drag a window by its title bar to a
//  screen edge or corner and a preview of the snapped rect shows; release
//  there and the window snaps. Hold the snap modifiers (Control Option by
//  default) during the drag and a zone map of the display shows instead;
//  release over a zone and the window snaps to it.
//
//  Listen-only: global NSEvent monitors observe the mouse and never swallow
//  or change an event, so the app being dragged sees exactly what it would
//  without Wharf. A press is only treated as a window drag once the window
//  under it is seen following the pointer, which rules out content drags
//  (selecting text) and native resizes. Wharf's own windows and full-screen
//  windows are skipped. The snap itself goes through
//  WindowSnapService.perform, so the dock strip, the gap and Restore work the
//  same as from the keyboard. The zone math is in WindowSnapDragZones.swift.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): the edge-snap drag flow of WindowLayoutService and
//  WindowGestureSupport. Vorssaint uses an active event tap so it can keep
//  the pointer off the system's top-edge gesture; this one is listen-only.
//

import AppKit
import ApplicationServices
import Combine

final class WindowSnapDragService {
    static let shared = WindowSnapDragService()

    private let preferences = DockyPreferences.shared
    private let registry = WindowRegistry.shared
    private let overlay = WindowSnapDragOverlay()
    private let systemWide = AXUIElementCreateSystemWide()
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    /// The window a press landed on, and where it and the pointer were then.
    /// Frames and points in AX space (origin top-left of the primary display).
    private struct Drag {
        let element: AXUIElement
        let pid: pid_t
        let initialFrame: CGRect
        let pointerStart: CGPoint
    }

    private enum Phase {
        case idle
        /// Pressed on a window; not yet proven to be a move.
        case pressed(Drag)
        /// The window follows the pointer.
        case moving(Drag)
        /// This press is not a window move; wait for the next one.
        case ignored
    }

    private var phase: Phase = .idle
    private var trail = WindowSnapDragPointerTrail()
    private var dwell = WindowSnapDragDwell<WindowSnapDragZones.EdgeHit>()
    private var armed: (action: WindowSnapAction, screen: NSScreen)?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var reevaluation: DispatchWorkItem?

    private init() {}

    func start() {
        // No messaging timeout is set here: on the system-wide element it
        // would apply to every AX call Wharf makes, not just this hit test.
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.windowSnapEnabled
            _ = DockyPreferences.shared.windowSnapEdgeDragEnabled
            _ = DockyPreferences.shared.windowSnapModifierDragEnabled
            self?.updateMonitors()
        }
        .store(in: &cancellables)
    }

    /// True when macOS's own drag-to-edge tiling is on, which would act on
    /// the same drags. Shown as a warning in the settings pane.
    static var isSystemTilingEnabled: Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.WindowManager") else { return false }
        let spaces = UserDefaults(suiteName: "com.apple.spaces")
        let displaysSpan = spaces?.object(forKey: "spans-displays") != nil && spaces?.bool(forKey: "spans-displays") == true
        return WindowSnapDragZones.systemTilingEnabled(
            valueFor: { key in defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key) },
            displaysSpan: displaysSpan
        )
    }

    // MARK: - Monitors

    private var isActive: Bool {
        preferences.windowSnapEnabled
            && (preferences.windowSnapEdgeDragEnabled || preferences.windowSnapModifierDragEnabled)
    }

    private func updateMonitors() {
        if isActive {
            guard monitors.isEmpty else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.handle(event)
            }) {
                monitors.append(monitor)
            }
        } else {
            for monitor in monitors {
                NSEvent.removeMonitor(monitor)
            }
            monitors.removeAll()
            reset()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            lastFlags = event.modifierFlags
            phase = beginDrag(at: axPointer()).map(Phase.pressed) ?? .ignored
        case .leftMouseDragged:
            lastFlags = event.modifierFlags
            dragged(at: event.timestamp)
        case .leftMouseUp:
            released()
        case .flagsChanged:
            lastFlags = event.modifierFlags
            if case .moving = phase { evaluate() }
        case .keyDown:
            // Escape drops the snap; the window stays wherever it is let go.
            if event.keyCode == 53, case .moving = phase {
                reset()
                phase = .ignored
            }
        default:
            break
        }
    }

    // MARK: - Drag tracking

    private func beginDrag(at point: CGPoint) -> Drag? {
        guard isActive, AXIsProcessTrusted() else { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let window = windowElement(containing: hit),
              boolAttribute("AXFullScreen", of: window) != true,
              let frame = frame(of: window),
              !WindowSnapDragZones.startsAtResizeHandle(point, frame: frame)
        else { return nil }
        return Drag(element: window, pid: pid, initialFrame: frame, pointerStart: point)
    }

    private func dragged(at timestamp: TimeInterval) {
        switch phase {
        case .pressed(let drag):
            let pointer = axPointer()
            let distance = hypot(pointer.x - drag.pointerStart.x, pointer.y - drag.pointerStart.y)
            guard distance >= WindowSnapDragZones.dragSlop else { return }
            guard let current = frame(of: drag.element) else {
                phase = .ignored
                return
            }
            switch WindowSnapDragZones.classify(
                initialFrame: drag.initialFrame,
                currentFrame: current,
                pointerStart: drag.pointerStart,
                pointerNow: pointer
            ) {
            case .moving:
                phase = .moving(drag)
                trail.reset()
                trail.append(NSEvent.mouseLocation, at: timestamp)
                evaluate()
            case .waiting:
                if distance > WindowSnapDragZones.giveUpDistance { phase = .ignored }
            case .resizing, .unrelated:
                phase = .ignored
            }
        case .moving:
            trail.append(NSEvent.mouseLocation, at: timestamp)
            evaluate()
        case .idle, .ignored:
            break
        }
    }

    private func released() {
        defer { reset() }
        guard case .moving(let drag) = phase, let armed else { return }
        let action = armed.action
        let screen = armed.screen
        // Let the app finish its own end of the move before resizing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let window = self.registry.window(for: drag.element, pid: drag.pid) else { return }
            WindowSnapService.shared.perform(action, on: window, screen: screen)
        }
    }

    private func reset() {
        reevaluation?.cancel()
        reevaluation = nil
        overlay.hide()
        armed = nil
        dwell.reset()
        trail.reset()
        phase = .idle
    }

    // MARK: - Zones

    /// Works out what a release right now would do, and shows it.
    private func evaluate() {
        reevaluation?.cancel()
        reevaluation = nil
        guard isActive, case .moving = phase else { return }

        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let now = ProcessInfo.processInfo.systemUptime
        let gap = WindowSnapGeometry.clampedGap(preferences.windowSnapGap)

        let modifierHeld = preferences.windowSnapModifierDragEnabled
            && preferences.windowSnapDragModifiers.matches(eventFlags: lastFlags.rawValue)
        if modifierHeld,
           let index = WindowSnapDragZones.screenIndex(for: pointer, in: screens.map(\.frame), slack: 4) {
            dwell.reset()
            let screen = screens[index]
            let area = WindowSnapService.shared.usableArea(of: screen)
            guard let action = WindowSnapDragZones.modifierAction(at: pointer, in: area) else { return disarm() }
            armed = (action, screen)
            overlay.show(
                screenFrame: screen.frame,
                target: WindowSnapGeometry.targetRect(for: action, current: area, area: area, gap: gap),
                zones: WindowSnapDragZones.modifierZones(in: area),
                highlighted: action
            )
            return
        }

        guard preferences.windowSnapEdgeDragEnabled else { return disarm() }
        let velocity = trail.velocity(at: now)
        let hit = WindowSnapDragZones.edgeHit(
            at: pointer,
            screens: screens.map { WindowSnapDragZones.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) },
            velocity: velocity,
            hitZone: WindowSnapDragZones.clampedHitZone(preferences.windowSnapDragHitZone)
        )
        let dwellTime = WindowSnapDragZones.clampedDwell(preferences.windowSnapDragDwell)
        if let ready = dwell.update(hit, at: now, dwell: dwellTime), screens.indices.contains(ready.screenIndex) {
            let screen = screens[ready.screenIndex]
            let area = WindowSnapService.shared.usableArea(of: screen)
            armed = (ready.action, screen)
            overlay.show(
                screenFrame: screen.frame,
                target: WindowSnapGeometry.targetRect(for: ready.action, current: area, area: area, gap: gap)
            )
            return
        }

        disarm()
        // The pointer may stop with no further events: check again once the
        // dwell runs out, or once it has rested long enough to read as slow
        // at a seam it was crossing fast.
        let wait = dwell.remaining(at: now, dwell: dwellTime)
            ?? (velocity == .zero ? nil : WindowSnapDragPointerTrail.stillAfter + 0.02)
        if let wait {
            let work = DispatchWorkItem { [weak self] in self?.evaluate() }
            reevaluation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    private func disarm() {
        armed = nil
        overlay.hide()
    }

    // MARK: - Accessibility helpers

    /// The pointer in AX space.
    private func axPointer() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    /// The window an element belongs to: itself, its AXWindow attribute, or
    /// the first window among its ancestors.
    private func windowElement(containing element: AXUIElement) -> AXUIElement? {
        if stringAttribute(kAXRoleAttribute, of: element) == kAXWindowRole as String {
            return element
        }
        if let window = elementAttribute(kAXWindowAttribute, of: element) {
            return window
        }
        var current = element
        for _ in 0..<32 {
            guard let parent = elementAttribute(kAXParentAttribute, of: current) else { return nil }
            if stringAttribute(kAXRoleAttribute, of: parent) == kAXWindowRole as String {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
