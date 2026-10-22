//
//  WindowSnapService.swift
//  Wharf
//
//  Snaps the frontmost window to halves, thirds, quarters, sixths, corners,
//  maximize, center or another display, from global shortcuts. The geometry
//  lives in WindowSnapGeometry.swift; this file reads the screens and the
//  docks, moves the window through WindowRegistry, and owns the hot keys.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): WindowLayoutService's apply and settle steps and
//  WindowMaximizerSupport's dock-overshoot retry.
//
//  The usable area of a screen is its visibleFrame minus the strip of any
//  Wharf dock on it, so a snapped window never lands under Wharf even when
//  Resize Windows is off, and WindowReservationService has nothing to undo.
//

import AppKit
import Carbon
import Combine
import Observation

@Observable
final class WindowSnapService {
    static let shared = WindowSnapService()

    /// Actions whose shortcut could not be registered, almost always because
    /// another app already holds that combination. Shown in the settings pane.
    private(set) var unavailableActions: Set<WindowSnapAction> = []

    @ObservationIgnored private let preferences = DockyPreferences.shared
    @ObservationIgnored private let registry = WindowRegistry.shared
    @ObservationIgnored private var history = WindowSnapHistory<WindowID>()
    @ObservationIgnored private var hotKeyRefs: [WindowSnapAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var hotKeyHandlerRef: EventHandlerRef?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    /// 'WSNP'. Distinct from the Launchpad and switcher signatures so each
    /// Carbon handler only answers its own keys.
    nonisolated static let hotKeySignature = OSType(0x57534E50)

    private init() {}

    func start() {
        installHotKeyHandlerIfNeeded()
        observeChanges { [weak self] in
            _ = DockyPreferences.shared.windowSnapEnabled
            _ = DockyPreferences.shared.windowSnapShortcutOverrides
            self?.registerHotKeys()
        }
        .store(in: &cancellables)
    }

    // MARK: - Snapping

    /// Applies `action` to `window`, or to the frontmost window when nil.
    /// Returns false when there is no window, no permission, or nothing to do
    /// (Restore with no history, a display move with one display).
    @discardableResult
    func perform(_ action: WindowSnapAction, on window: AppWindow? = nil) -> Bool {
        guard AXIsProcessTrusted() else {
            PermissionsService.shared.presentPermissionAlert(for: .accessibility, actionTitle: "snap windows")
            return false
        }
        guard let window = window ?? registry.frontmostWindow(),
              let primaryHeight = NSScreen.screens.first?.frame.height,
              let axFrame = registry.liveFrame(of: window) ?? window.frame
        else { return false }

        let current = WindowSnapGeometry.flipY(axFrame, primaryHeight: primaryHeight)
        let screens = NSScreen.screens
        guard let screenIndex = WindowSnapGeometry.indexOfLargestOverlap(current, in: screens.map(\.frame))
                ?? NSScreen.main.flatMap({ screens.firstIndex(of: $0) })
        else { return false }
        let area = usableArea(of: screens[screenIndex])
        let gap = WindowSnapGeometry.clampedGap(preferences.windowSnapGap)

        let target: CGRect
        let targetArea: CGRect
        switch action {
        case .restore:
            guard let previous = history.popPrevious(for: window.id, current: current) else { return false }
            target = previous
            targetArea = area
        case .nextDisplay, .previousDisplay:
            guard let destinationIndex = WindowSnapGeometry.adjacentDisplayIndex(
                currentIndex: screenIndex,
                frames: screens.map(\.frame),
                forward: action == .nextDisplay
            ) else { return false }
            targetArea = usableArea(of: screens[destinationIndex])
            target = WindowSnapGeometry.rectForDisplay(current: current, source: area, destination: targetArea)
            remember(current, for: window)
        default:
            targetArea = area
            target = WindowSnapGeometry.targetRect(for: action, current: current, area: area, gap: gap)
            remember(current, for: window)
        }

        guard !WindowSnapGeometry.isClose(current, target, tolerance: 1) else { return true }
        return apply(target, to: window, action: action, area: targetArea, primaryHeight: primaryHeight)
    }

    /// Screen visibleFrame minus the strip of every visible Wharf dock on it.
    func usableArea(of screen: NSScreen) -> CGRect {
        var area = screen.visibleFrame
        for dock in NSApp.windows.compactMap({ $0 as? MainWindow }) where dock.screen == screen {
            area = WindowSnapGeometry.subtractingDock(dock.currentReservationFrame, from: area)
        }
        return area
    }

    private func remember(_ frame: CGRect, for window: AppWindow) {
        history.removeStale(keeping: Set(registry.windows.map(\.id)).union([window.id]))
        history.record(frame, for: window.id)
    }

    private func apply(
        _ target: CGRect,
        to window: AppWindow,
        action: WindowSnapAction,
        area: CGRect,
        primaryHeight: CGFloat
    ) -> Bool {
        let axTarget = WindowSnapGeometry.flipY(target, primaryHeight: primaryHeight)
        guard registry.resize(window, to: axTarget) else { return false }

        // Crossing displays can clamp the size to the old screen before the
        // move lands, so a second pass settles it on the new one.
        if action == .nextDisplay || action == .previousDisplay {
            registry.resize(window, to: axTarget)
        }

        guard let actualAX = registry.liveFrame(of: window) else { return true }

        // Some apps refuse a size that would put an edge under a side dock
        // and stay wider than asked. Taking the size from a point slightly up
        // and left, then moving onto the target, is accepted in full.
        if WindowSnapGeometry.overshoots(actualAX.size, target: axTarget.size) {
            let tolerance = WindowSnapGeometry.frameTolerance
            let approach = CGRect(
                x: axTarget.minX - tolerance,
                y: axTarget.minY - tolerance,
                width: axTarget.width,
                height: axTarget.height
            )
            registry.resize(window, to: approach)
            registry.move(window, to: axTarget.origin)
        }

        // An app with a minimum or fixed size keeps its own size; re-anchor it
        // to the edge the action is about instead of leaving it off target.
        guard let settledAX = registry.liveFrame(of: window) else { return true }
        let sizeMissed = abs(settledAX.width - axTarget.width) > WindowSnapGeometry.frameTolerance
            || abs(settledAX.height - axTarget.height) > WindowSnapGeometry.frameTolerance
        if sizeMissed, action != .restore {
            let anchored = WindowSnapGeometry.anchoredRect(
                for: action,
                target: target,
                actualSize: settledAX.size,
                area: area
            )
            registry.move(window, to: WindowSnapGeometry.flipY(anchored, primaryHeight: primaryHeight).origin)
        }
        return true
    }

    // MARK: - Shortcut conflicts

    /// Why `shortcut` cannot be used for `action`, or nil when it is free.
    /// Covers the other snap actions and every global combination Wharf
    /// already owns.
    func conflictMessage(for shortcut: KeyboardShortcut, action: WindowSnapAction) -> String? {
        guard shortcut.isValid else { return nil }

        var reserved: [(name: String, shortcut: KeyboardShortcut)] = []
        if preferences.launchpadShortcut.isValid {
            reserved.append(("the Launchpad shortcut", preferences.launchpadShortcut))
        }
        let switcher = preferences.windowSwitcherShortcut
        if switcher.isValid {
            reserved.append(("the Window Switcher shortcut", switcher))
            // The switcher also registers its shortcut plus Shift to go backward.
            reserved.append((
                "the Window Switcher reverse shortcut",
                KeyboardShortcut(keyCode: switcher.keyCode, modifierFlags: switcher.modifierFlags.union(.shift))
            ))
        }
        if preferences.windowsKeyboardMode, preferences.windowsKeyboardSnipShortcut {
            reserved.append((
                "the Windows snip shortcut",
                KeyboardShortcut(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.command, .shift])
            ))
        }

        var assigned: [WindowSnapAction: KeyboardShortcut] = [:]
        for other in WindowSnapAction.allCases {
            if let existing = preferences.windowSnapShortcut(for: other) { assigned[other] = existing }
        }

        switch WindowSnapShortcuts.conflict(for: shortcut, excluding: action, assigned: assigned, reserved: reserved) {
        case .action(let other):
            return "\(shortcut.displayString) is already used by \(other.title)."
        case .reserved(let name):
            return "\(shortcut.displayString) is already used by \(name)."
        case nil:
            break
        }

        let flags = shortcut.modifierFlags
        if preferences.windowsKeyboardMode,
           flags.contains(.control),
           !flags.contains(.command),
           WindowsKeyboardService.translatedKeyCodes.contains(Int64(shortcut.keyCode)) {
            return "Windows Keyboard Mode turns Control plus this key into Command, so \(shortcut.displayString) would never arrive."
        }
        return nil
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        unregisterHotKeys()
        var unavailable: Set<WindowSnapAction> = []

        if preferences.windowSnapEnabled {
            for action in WindowSnapAction.allCases {
                guard let shortcut = preferences.windowSnapShortcut(for: action), shortcut.isValid else { continue }
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    UInt32(shortcut.keyCode),
                    shortcut.carbonModifierFlags,
                    EventHotKeyID(signature: Self.hotKeySignature, id: action.hotKeyID),
                    GetApplicationEventTarget(),
                    0,
                    &ref
                )
                if status == noErr, let ref {
                    hotKeyRefs[action] = ref
                } else {
                    unavailable.insert(action)
                }
            }
        }

        if unavailable != unavailableActions {
            unavailableActions = unavailable
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr,
                  hotKeyID.signature == WindowSnapService.hotKeySignature,
                  let action = WindowSnapAction(hotKeyID: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }

            Task { @MainActor in
                WindowSnapService.shared.perform(action)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            nil,
            &hotKeyHandlerRef
        )
    }
}
