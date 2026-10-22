//
//  FocusFollowsMouseService.swift
//  Wharf
//
//  Focus follows mouse, Unix style: rest the pointer on a window for the
//  chosen pause and that window comes to the front with keyboard focus, no
//  click needed. Only on the displays the user opted in, never while a menu
//  is open, a button is down or a modifier is held, never for excluded apps,
//  Wharf's own windows or the Dock.
//
//  Adapted from Vorssaint's FocusFollowsMouseService (vorssaint/vorssaint-utils,
//  GPL-3.0), using public window server lists instead of its private helpers.
//  The decisions live in FocusAndWinTapLogic.swift.
//

import AppKit
import ApplicationServices
import Combine

final class FocusFollowsMouseService {
    static let shared = FocusFollowsMouseService()

    private let preferences = BehaviorExtrasPreferences.shared
    private var mouseMonitor: Any?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables: Set<AnyCancellable> = []
    private var state = HoverDwellState()

    private init() {}

    func start() {
        observePreferences()
        // A grant made after launch arms the feature without a relaunch.
        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.focusFollowsMouseEnabled
            _ = preferences.focusFollowsMouseDisplays
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.sync()
                self?.observePreferences()
            }
        }
    }

    /// Runs only while it can do something: switched on, at least one display
    /// opted in, and Accessibility granted. Otherwise no monitor at all.
    private func sync() {
        let wanted = preferences.focusFollowsMouseEnabled
            && !preferences.focusFollowsMouseDisplays.isEmpty
            && AXIsProcessTrusted()
        wanted ? install() : uninstall()
    }

    private func install() {
        guard mouseMonitor == nil else { return }
        // Drags are watched too, so the pause starts over once a drag ends
        // instead of firing the moment the button comes up.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            self?.recordMovement(to: point)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.resetMovement()
            }))
        }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resetMovement() }))
    }

    private func uninstall() {
        resetMovement()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        observers.forEach { center, token in center.removeObserver(token) }
        observers.removeAll()
    }

    private func recordMovement(to point: CGPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.recordMovement(to: point) }
            return
        }
        guard mouseMonitor != nil else { return }
        state.recordMovement(to: point, at: ProcessInfo.processInfo.systemUptime)
        startTimerIfNeeded()
    }

    private func resetMovement() {
        state.reset()
        timer?.invalidate()
        timer = nil
    }

    /// A 50 ms check runs only while a pause is being timed, so an idle
    /// pointer costs nothing.
    private func startTimerIfNeeded() {
        guard timer == nil, state.hasPendingEvaluation else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.evaluateIfSettled() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func evaluateIfSettled() {
        defer {
            if !state.hasPendingEvaluation {
                timer?.invalidate()
                timer = nil
            }
        }
        guard let evaluation = state.nextEvaluation(
            at: ProcessInfo.processInfo.systemUptime,
            delayMilliseconds: preferences.focusFollowsMouseDelay
        ) else { return }
        defer { state.finishEvaluation(evaluation) }

        // `focus` below would put up a permission alert when Accessibility is
        // missing. A hover feature must never do that, so both the live answer
        // and the cached one have to agree first.
        guard AXIsProcessTrusted(), PermissionsService.shared.accessibility == .granted else { return }

        let decision = HoverFocusGate.decide(input(at: evaluation.point))
        guard case let .raise(windowID, pid) = decision,
              let window = WindowRegistry.shared.liveWindows(for: pid).first(where: { $0.cgWindowID == windowID })
        else { return }
        // The window lookup above asks the app over Accessibility, which takes
        // long enough for a click or a shortcut to begin. Check again.
        guard state.isCurrent(evaluation), !Self.isButtonOrModifierHeld else { return }
        WindowRegistry.shared.focus(window)
    }

    private static var isButtonOrModifierHeld: Bool {
        NSEvent.pressedMouseButtons != 0
            || !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Everything the gate needs, read from the window server and AppKit.
    /// `point` is in global display coordinates, origin at the top left of
    /// the main display.
    private func input(at point: CGPoint) -> HoverFocusInput {
        var input = HoverFocusInput()
        input.ownPID = ProcessInfo.processInfo.processIdentifier
        input.mouseButtonsDown = NSEvent.pressedMouseButtons != 0
        input.modifiersHeld = !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        input.excludedBundleIDs = Set(preferences.focusFollowsMouseExcludedBundleIDs)
        input.displayEnabled = isDisplayEnabled(at: point)

        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = raw.compactMap(HoverWindowScan.info(from:))
        input.menuOpen = HoverWindowScan.isMenuOpen(in: windows)
        input.target = HoverWindowScan.target(in: windows, at: point, pointerWindowID: Self.receivingWindow(at: point))

        if let target = input.target, let app = NSRunningApplication(processIdentifier: target.ownerPID) {
            input.targetBundleID = app.bundleIdentifier
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        input.frontmostPID = frontmost
        if let frontmost, frontmost == input.target?.ownerPID {
            input.focusedWindowID = Self.focusedWindowID(of: frontmost)
        }
        return input
    }

    private func isDisplayEnabled(at point: CGPoint) -> Bool {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0,
              let key = PerDisplaySettings.key(for: displayID) else { return false }
        return preferences.focusFollowsMouseDisplays.contains(key)
    }

    /// AppKit's answer to which window a click here would reach. It skips
    /// overlays that let clicks through, which the window server list cannot
    /// tell apart.
    private static func receivingWindow(at point: CGPoint) -> CGWindowID? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let appKitPoint = NSPoint(x: point.x, y: mainHeight - point.y)
        let number = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
        return number > 0 ? CGWindowID(number) : nil
    }

    private static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(value as! AXUIElement, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }
}
