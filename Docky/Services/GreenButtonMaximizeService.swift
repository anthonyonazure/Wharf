//
//  GreenButtonMaximizeService.swift
//  Wharf
//
//  Makes a window's green button fill the screen's usable area (the space
//  left by the menu bar, the macOS Dock and every Wharf dock, minus the snap
//  gap) instead of entering macOS full screen. A second click puts the window
//  back. Holding Option gives the real full screen; any other modifier, and
//  every app on the exception list, keeps the app's own behavior.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): WindowMaximizer's tap, its Accessibility hit test and
//  the window walk that never asks an application element for its role.
//  The frame math and the move go through WindowSnapService, so this feature
//  and the Maximize shortcut land on exactly the same rectangle.
//
//  The tap never asks Accessibility anything. Each window's green button is
//  looked up ahead of time, when the pointer moves over a title bar, and
//  kept in a small cache; a press is held back only when the cache already
//  says, for the exact window in front at that point, that the press landed
//  on its green button. Anything else (no answer yet, a window that moved,
//  a cache from another window) passes through to the app untouched. Right
//  before acting, Accessibility confirms the click really hit that button.
//
//  The press and release of a click are kept together by
//  GreenButtonPairTracker. Holding the button down hands the press back to
//  the app after a moment, so the macOS tiling menu still opens on a hold.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics

final class GreenButtonMaximizeService {
    static let shared = GreenButtonMaximizeService()

    /// Set on presses this service hands back, so its own tap lets them by.
    nonisolated static let syntheticMarker: Int64 = 0x5748_4742 // "WHGB"

    private let preferences = WindowBehaviorPreferences.shared
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var moveMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private var pair = GreenButtonPairTracker()
    private var pendingClick: PendingClick?
    private var heldPress: CGEvent?
    private var holdWork: DispatchWorkItem?

    private var cache: [CGWindowID: ZoomTarget] = [:]
    private var fillsInFlight: Set<CGWindowID> = []
    private var lastMoveCheck = Date.distantPast
    private var rightToLeft = false

    nonisolated private static let messagingTimeout: Float = 0.35
    private let mouseUpTolerance: CGFloat = 8
    /// How long a cached answer is trusted, as long as the window has not
    /// moved or resized since.
    private let cacheLifetime: TimeInterval = 120

    /// What Accessibility said about one window's green button, read off the
    /// tap. Coordinates are global, top down, like the window server's.
    private struct ZoomTarget {
        let pid: pid_t
        let windowID: CGWindowID
        let bundleIdentifier: String?
        let windowBounds: CGRect
        let buttonFrame: CGRect
        let button: AXUIElement?
        /// The window's zoom and full screen button elements. Some apps
        /// report the green button under either; a hit on any of them is a
        /// hit on the green button.
        let greenButtons: [AXUIElement]
        /// The classic zoom button may be pressed for the app when Wharf
        /// cannot move the window; a full screen button may not, since that
        /// would do the very thing the user turned this feature on to avoid.
        let allowsNativeFallback: Bool
        /// False for windows to leave alone: excepted apps, full screen
        /// windows, or no green button found. Cached so the lookup is not
        /// repeated on every move.
        let isUsable: Bool
        let filledAt: Date
    }

    private struct PendingClick {
        let token: Int
        let target: ZoomTarget
        let point: CGPoint
        let action: GreenButtonAction
    }

    private init() {}

    func start() {
        observeChanges { [weak self] in
            _ = WindowBehaviorPreferences.shared.maximizeEnabled
            _ = WindowBehaviorPreferences.shared.maximizeExceptions
            self?.cache.removeAll()
            self?.syncTapState()
        }
        .store(in: &cancellables)

        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTapState() }
            .store(in: &cancellables)
    }

    private func syncTapState() {
        if preferences.maximizeEnabled, AXIsProcessTrusted() {
            installTap()
        } else {
            removeTap()
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        // Apps follow the user's first language, so its writing direction
        // says which corner the traffic lights sit in.
        rightToLeft = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en").characterDirection == .rightToLeft
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<GreenButtonMaximizeService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Wharf] Green button maximize: could not create the event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Listen only: looks the green button up ahead of a click.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        tap = nil
        runLoopSource = nil
        interrupt()
        cache.removeAll()
    }

    /// Events may have passed unseen: forget the held press so its release
    /// goes through, and drop the pending action.
    private func interrupt() {
        pair.interrupted()
        pendingClick = nil
        heldPress = nil
        holdWork?.cancel()
        holdWork = nil
    }

    // MARK: - Event routing (cached answers only)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt()
            if let tap, preferences.maximizeEnabled {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            pair.pressPassed()
            pendingClick = nil
            holdWork?.cancel()
            let flags = event.flags
            let action = GreenButtonLogic.action(
                command: flags.contains(.maskCommand),
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate),
                shift: flags.contains(.maskShift)
            )
            guard action != .passThrough,
                  let target = cachedTarget(at: event.location)
            else { return Unmanaged.passUnretained(event) }

            let token = pair.pressSwallowed()
            pendingClick = PendingClick(token: token, target: target, point: event.location, action: action)
            heldPress = event.copy()
            let work = DispatchWorkItem { [weak self] in self?.holdElapsed(token: token) }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + GreenButtonPairTracker.holdSeconds, execute: work)
            return nil

        case .leftMouseDragged:
            return pair.dragged() == .swallow ? nil : Unmanaged.passUnretained(event)

        case .leftMouseUp:
            let inside = pendingClick.map {
                $0.target.buttonFrame.insetBy(dx: -mouseUpTolerance, dy: -mouseUpTolerance).contains(event.location)
            } ?? false
            switch pair.released(insideButton: inside) {
            case .pass, .replayPress:
                return Unmanaged.passUnretained(event)
            case .swallow:
                clearPending()
                return nil
            case .perform(let token):
                if let click = pendingClick, click.token == token {
                    DispatchQueue.main.async { [weak self] in self?.perform(click) }
                }
                clearPending()
                return nil
            }

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The cached green button under `point`, only if the window in front
    /// there is exactly the cached window, unmoved, and the point is on the
    /// button itself. One window server read; no Accessibility.
    private func cachedTarget(at point: CGPoint) -> ZoomTarget? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let candidate = TrafficLightHitTest.candidate(
            in: windows, at: point, button: .zoom, ownProcessID: getpid(), rightToLeft: rightToLeft
        ) else { return nil }
        guard let target = cache[candidate.windowID],
              target.isUsable,
              target.pid == candidate.pid,
              Self.sameRect(target.windowBounds, candidate.frame),
              Date().timeIntervalSince(target.filledAt) < cacheLifetime,
              target.buttonFrame.contains(point),
              !WindowBehaviorBundleList.contains(target.bundleIdentifier, in: preferences.maximizeExceptions)
        else {
            // No trustworthy answer: the click goes to the app, and the
            // lookup runs so the next one can be handled.
            scheduleFill(candidate)
            return nil
        }
        return target
    }

    private func holdElapsed(token: Int) {
        guard pair.holdElapsed(token: token) == .replayPress else { return }
        // Held down: the user wants the app's own hold (the tiling menu).
        // Hand the press back where it happened; its release will follow.
        if let press = heldPress {
            press.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            press.post(tap: .cghidEventTap)
        }
        clearPending()
    }

    private func clearPending() {
        pendingClick = nil
        heldPress = nil
        holdWork?.cancel()
        holdWork = nil
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: - Looking the button up ahead of time

    private func pointerMoved() {
        let now = Date()
        guard now.timeIntervalSince(lastMoveCheck) > 0.08,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return }
        lastMoveCheck = now
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let candidate = TrafficLightHitTest.candidate(
            in: windows, at: point, button: .zoom, ownProcessID: getpid(), rightToLeft: rightToLeft
        ) else { return }
        if let cached = cache[candidate.windowID],
           Self.sameRect(cached.windowBounds, candidate.frame),
           now.timeIntervalSince(cached.filledAt) < cacheLifetime {
            return
        }
        scheduleFill(candidate)
    }

    /// Looks the green button up on a private queue, so an app that answers
    /// Accessibility slowly (or not at all) never holds up the main thread,
    /// where both input taps run. Only the cache write comes back to main.
    private func scheduleFill(_ candidate: TrafficLightCandidate) {
        guard tap != nil, fillsInFlight.insert(candidate.windowID).inserted else { return }
        let bundleIdentifier = NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier
        if WindowBehaviorBundleList.contains(bundleIdentifier, in: preferences.maximizeExceptions) {
            fillsInFlight.remove(candidate.windowID)
            store(nil, for: candidate, bundleIdentifier: bundleIdentifier)
            return
        }
        Self.lookUpQueue.async { [weak self] in
            let found = Self.lookUp(pid: candidate.pid, windowID: candidate.windowID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fillsInFlight.remove(candidate.windowID)
                guard self.tap != nil else { return }
                self.store(found, for: candidate, bundleIdentifier: bundleIdentifier)
            }
        }
    }

    private func store(_ found: LookUp?, for candidate: TrafficLightCandidate, bundleIdentifier: String?) {
        if cache.count > 64 {
            let cutoff = Date().addingTimeInterval(-cacheLifetime)
            cache = cache.filter { $0.value.filledAt > cutoff }
            if cache.count > 64 { cache.removeAll() }
        }
        cache[candidate.windowID] = ZoomTarget(
            pid: candidate.pid, windowID: candidate.windowID, bundleIdentifier: bundleIdentifier,
            windowBounds: candidate.frame, buttonFrame: found?.frame ?? .zero, button: found?.button,
            greenButtons: found?.all ?? [], allowsNativeFallback: found?.allowsNativeFallback ?? false,
            isUsable: found != nil, filledAt: Date()
        )
    }

    nonisolated private static let lookUpQueue = DispatchQueue(label: "wharf.greenButton.lookUp", qos: .userInitiated)

    nonisolated private struct LookUp {
        let button: AXUIElement
        let all: [AXUIElement]
        let frame: CGRect
        let allowsNativeFallback: Bool
    }

    /// The green button of one window, or nil for a window to leave alone
    /// (not found, full screen, no enabled button). Runs on lookUpQueue.
    nonisolated private static func lookUp(pid: pid_t, windowID: CGWindowID) -> LookUp? {
        guard let window = axWindow(pid: pid, windowID: windowID),
              !boolAttribute(window, "AXFullScreen"),
              let button = greenButton(in: window)
        else { return nil }
        let all = [kAXZoomButtonAttribute as String, kAXFullScreenButtonAttribute as String]
            .compactMap { elementAttribute(window, $0) }
        return LookUp(button: button.element, all: all, frame: button.frame,
                      allowsNativeFallback: button.allowsNativeFallback)
    }

    // MARK: - Acting on a click

    private func perform(_ click: PendingClick) {
        guard let button = click.target.button, hitIsOnButton(click.target.greenButtons, at: click.point) else {
            // The press did not land on the green button after all (the
            // window changed under it). Both halves were held back, so
            // dropping the click leaves the app consistent.
            cache[click.target.windowID] = nil
            return
        }

        let registry = WindowRegistry.shared
        guard let window = registry.liveWindows(for: click.target.pid)
                .first(where: { $0.cgWindowID == click.target.windowID })
        else {
            pressNatively(click)
            return
        }

        // A green button click on a window behind others brings it forward,
        // as a click on any part of a window does.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != click.target.pid {
            registry.focus(window)
        }

        switch click.action {
        case .passThrough:
            pressNatively(click)
        case .nativeFullScreen:
            if !registry.setFullscreen(window, fullscreen: true) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        case .toggleMaximize:
            let snap = WindowSnapService.shared
            if isMaximized(window) {
                // Nothing to restore (maximized some other way) leaves it be,
                // as the classic zoom does on a window already at full size.
                snap.perform(.restore, on: window)
            } else if !snap.perform(.maximize, on: window) {
                pressNatively(click)
            }
        }
        // The window's frame changed; look the button up again next time.
        cache[click.target.windowID] = nil
    }

    /// Whether the window already sits on the Maximize rectangle. Worked out
    /// here rather than by calling Maximize, which would record the maximized
    /// frame as the one to restore.
    private func isMaximized(_ window: AppWindow) -> Bool {
        guard let axFrame = WindowRegistry.shared.liveFrame(of: window) ?? window.frame,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return false }
        let current = WindowSnapGeometry.flipY(axFrame, primaryHeight: primaryHeight)
        let screens = NSScreen.screens
        guard let index = WindowSnapGeometry.indexOfLargestOverlap(current, in: screens.map(\.frame)) else { return false }
        let target = WindowSnapGeometry.targetRect(
            for: .maximize,
            current: current,
            area: WindowSnapService.shared.usableArea(of: screens[index]),
            gap: WindowSnapGeometry.clampedGap(DockyPreferences.shared.windowSnapGap)
        )
        return GreenButtonLogic.isMaximized(current, target: target)
    }

    private func pressNatively(_ click: PendingClick) {
        guard click.target.allowsNativeFallback, let button = click.target.button else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    // MARK: - Accessibility helpers (never called from the tap)

    /// The element Accessibility finds at `point` must be one of the cached
    /// green button elements itself or something inside it. A nearby title
    /// bar does not count.
    private func hitIsOnButton(_ buttons: [AXUIElement], at point: CGPoint) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit
        else { return false }
        AXUIElementSetMessagingTimeout(current, Self.messagingTimeout)
        for _ in 0..<4 {
            if buttons.contains(where: { CFEqual(current, $0) }) { return true }
            guard let parent = Self.elementAttribute(current, kAXParentAttribute as String) else { return false }
            current = parent
        }
        return false
    }

    /// The Accessibility window with this window server id. The app element
    /// is only asked for its window list, never its role, which would switch
    /// a Chromium app into full accessibility mode.
    nonisolated private static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for window in windows {
            // Bounded before the first question, so a hung app costs at most
            // the timeout per window, on the look-up queue.
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success, id == windowID {
                AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
                return window
            }
        }
        return nil
    }

    nonisolated private static func greenButton(in window: AXUIElement)
        -> (element: AXUIElement, frame: CGRect, allowsNativeFallback: Bool)? {
        for (attribute, allowsNativeFallback) in [
            (kAXZoomButtonAttribute as String, true),
            (kAXFullScreenButtonAttribute as String, false)
        ] {
            guard let button = elementAttribute(window, attribute),
                  boolAttribute(button, kAXEnabledAttribute as String, default: true),
                  let frame = frame(of: button)
            else { continue }
            return (button, frame, allowsNativeFallback)
        }
        return nil
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
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
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    nonisolated private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, Self.messagingTimeout)
        return result
    }

    nonisolated private static func boolAttribute(_ element: AXUIElement, _ attribute: String, default defaultValue: Bool = false) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return defaultValue }
        return (value as? Bool) ?? defaultValue
    }
}
