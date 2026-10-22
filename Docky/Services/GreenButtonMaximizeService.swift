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
//  The tap can swallow events, which a listen-only tap cannot: the press and
//  release of a confirmed green button click are the only events it holds
//  back. Everything else passes untouched.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics

final class GreenButtonMaximizeService {
    static let shared = GreenButtonMaximizeService()

    private let preferences = WindowBehaviorPreferences.shared
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingClick: PendingClick?
    private var cancellables: Set<AnyCancellable> = []

    private let messagingTimeout: Float = 0.35
    private let mouseUpTolerance: CGFloat = 8

    private struct PendingClick {
        let candidate: TrafficLightCandidate
        let button: AXUIElement
        let buttonFrame: CGRect
        let action: GreenButtonAction
        /// The classic zoom button may be pressed for the app when Wharf
        /// cannot move the window; a full screen button may not, since that
        /// would do the very thing the user turned this feature on to avoid.
        let allowsNativeFallback: Bool
    }

    private init() {}

    func start() {
        observeChanges { [weak self] in
            _ = WindowBehaviorPreferences.shared.maximizeEnabled
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
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
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
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        pendingClick = nil
    }

    // MARK: - Event routing

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, preferences.maximizeEnabled, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // A revoked permission would make the Accessibility hit test below
        // hang and freeze the pointer, so never ask without it.
        guard AXIsProcessTrusted() else {
            pendingClick = nil
            DispatchQueue.main.async { [weak self] in self?.syncTapState() }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            pendingClick = nil
            let flags = event.flags
            let action = GreenButtonLogic.action(
                command: flags.contains(.maskCommand),
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate),
                shift: flags.contains(.maskShift)
            )
            guard action != .passThrough,
                  let click = findClick(at: event.location, action: action)
            else { return Unmanaged.passUnretained(event) }
            pendingClick = click
            return nil

        case .leftMouseUp:
            guard let click = pendingClick else { return Unmanaged.passUnretained(event) }
            pendingClick = nil
            // Releasing away from the button cancels, as it does natively.
            if click.buttonFrame.insetBy(dx: -mouseUpTolerance, dy: -mouseUpTolerance).contains(event.location) {
                DispatchQueue.main.async { [weak self] in self?.perform(click) }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func findClick(at point: CGPoint, action: GreenButtonAction) -> PendingClick? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let exceptions = preferences.maximizeExceptions
        guard let candidate = TrafficLightHitTest.candidate(
                in: windows,
                at: point,
                button: .zoom,
                ownProcessID: getpid(),
                pidIsEligible: { pid in
                    !WindowBehaviorBundleList.contains(
                        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                        in: exceptions
                    )
                }
              ),
              let element = element(at: point),
              let window = topLevelWindow(from: element),
              pid(of: window) == candidate.pid,
              !boolAttribute(window, "AXFullScreen"),
              let button = greenButton(in: window, containing: point)
        else { return nil }

        return PendingClick(
            candidate: candidate,
            button: button.element,
            buttonFrame: button.frame,
            action: action,
            allowsNativeFallback: button.allowsNativeFallback
        )
    }

    // MARK: - Acting on a click

    private func perform(_ click: PendingClick) {
        let registry = WindowRegistry.shared
        guard let window = registry.liveWindows(for: click.candidate.pid)
                .first(where: { $0.cgWindowID == click.candidate.windowID })
        else {
            pressNatively(click)
            return
        }

        switch click.action {
        case .passThrough:
            pressNatively(click)
        case .nativeFullScreen:
            if !registry.setFullscreen(window, fullscreen: true) {
                AXUIElementPerformAction(click.button, kAXPressAction as CFString)
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
        guard click.allowsNativeFallback else { return }
        AXUIElementPerformAction(click.button, kAXPressAction as CFString)
    }

    // MARK: - Accessibility helpers

    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element
        else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Asking an application element for its role switches a Chromium app
    /// into full accessibility mode for the rest of its life, so the walk
    /// stops before it ever reaches one.
    private func isApplicationElement(_ element: AXUIElement) -> Bool {
        guard let pid = pid(of: element) else { return false }
        return CFEqual(element, AXUIElementCreateApplication(pid))
    }

    private func topLevelWindow(from element: AXUIElement) -> AXUIElement? {
        guard !isApplicationElement(element) else { return nil }
        if role(of: element) == kAXWindowRole as String { return element }
        for attribute in [kAXWindowAttribute as String, kAXTopLevelUIElementAttribute as String] {
            if let window = elementAttribute(element, attribute), role(of: window) == kAXWindowRole as String {
                return window
            }
        }
        var current = element
        for _ in 0..<8 {
            guard let parent = elementAttribute(current, kAXParentAttribute as String),
                  !isApplicationElement(parent)
            else { return nil }
            if role(of: parent) == kAXWindowRole as String { return parent }
            current = parent
        }
        return nil
    }

    private func greenButton(in window: AXUIElement, containing point: CGPoint)
        -> (element: AXUIElement, frame: CGRect, allowsNativeFallback: Bool)? {
        for (attribute, allowsNativeFallback) in [
            (kAXZoomButtonAttribute as String, true),
            (kAXFullScreenButtonAttribute as String, false)
        ] {
            guard let button = elementAttribute(window, attribute),
                  boolAttribute(button, kAXEnabledAttribute as String, default: true),
                  let frame = frame(of: button),
                  frame.insetBy(dx: -3, dy: -3).contains(point)
            else { continue }
            return (button, frame, allowsNativeFallback)
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
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, messagingTimeout)
        return result
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid == 0 ? nil : pid
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String, default defaultValue: Bool = false) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return defaultValue }
        return (value as? Bool) ?? defaultValue
    }
}
