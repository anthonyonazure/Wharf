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
//  Accessibility calls go to the target app and can stall for as long as
//  that app is busy, so the lookup runs off the main thread with a short
//  timeout on every element it touches. Each lookup gets its own worker
//  (at most two at once, see HoverWorkerLedger), so one stuck app holds one
//  slot instead of a queue the others wait behind. A lookup that misses its
//  deadline is abandoned by a watchdog, told to stop at its next step, and
//  its late answer ignored; switching the feature off cancels every lookup
//  still running. The worker also
//  checks that the window answers (one position read) before anything is
//  raised. The raise itself (WindowRegistry.focus) stays on the main thread
//  because it shares the registry's state; its few Accessibility calls are
//  bounded by the element's timeout: 0.25 s for an element found here, the
//  process-wide 1 s for one from the registry. Everything is checked again
//  on the main thread right before raising (HoverCommitCheck).
//

import AppKit
import ApplicationServices
import Combine

/// The same private call as in CGSPrivate.swift, declared again here without
/// main actor isolation so the worker queue can use it.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private nonisolated func hoverAXWindowID(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// An AXUIElement handed from the worker queue back to the main thread. AX
/// element references are safe to pass between threads.
private struct HoverAXElement: @unchecked Sendable {
    let element: AXUIElement
}

/// What a worker found, handed back to the main thread.
private nonisolated struct HoverLookupResult: @unchecked Sendable {
    let element: HoverAXElement?
    /// The target app's focused window, when the worker had to ask.
    let focusedWindowID: CGWindowID?
    /// Whether the element came from the registry's snapshot.
    let usedRegistryElement: Bool
}

/// `HoverWorkerLedger` behind a lock, for the worker threads.
private nonisolated final class HoverWorkerSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = HoverWorkerLedger()

    var canStart: Bool { lock.withLock { ledger.canStart } }
    func start() -> UInt64? { lock.withLock { ledger.start() } }
    func cancel(_ id: UInt64) { lock.withLock { ledger.cancel(id) } }
    func cancelAll() { lock.withLock { ledger.cancelAll() } }
    func shouldContinue(_ id: UInt64) -> Bool { lock.withLock { ledger.shouldContinue(id) } }
    func finish(_ id: UInt64) { lock.withLock { ledger.finish(id) } }
}

final class FocusFollowsMouseService {
    static let shared = FocusFollowsMouseService()

    /// How long one Accessibility message to the target app may take.
    private nonisolated static let axTimeout: Float = 0.25
    /// The most windows read from one app while looking for the target.
    private nonisolated static let maximumWindowsScanned = 64
    /// A lookup that answers later than this is dropped: the moment passed.
    private static let lookupDeadline: TimeInterval = 1.0

    private let preferences = BehaviorExtrasPreferences.shared
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables: Set<AnyCancellable> = []
    private var state = HoverDwellState()

    /// Concurrent, so a lookup stuck in a hung app does not hold up the
    /// next one. How many run at once is capped by `workers`.
    private let worker = DispatchQueue(label: "wharf.focus-follows-mouse.lookup", qos: .userInitiated,
                                       attributes: .concurrent)
    /// Whether an answer is still wanted (one at a time).
    private var lookup = HoverLookupTicket()
    /// Which lookups are still running, answered or not. Read by the worker
    /// threads, so behind a lock.
    private let workers = HoverWorkerSlots()
    /// Wharf's own menus being tracked. Wharf's windows are left out of the
    /// window server menu check, so its own menus are known from here.
    private var ownMenuDepth = 0

    private init() {}

    func start() {
        observePreferences()
        // A grant made after launch arms the feature without a relaunch.
        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        let center = NotificationCenter.default
        // Plugging in or removing a display can arm or disarm the feature
        // (see `isWanted`), so this one stays registered while uninstalled.
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        center.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.ownMenuDepth += 1 }
            .store(in: &cancellables)
        center.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.ownMenuDepth = max(0, self.ownMenuDepth - 1)
            }
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

    /// Needs a connected display among the saved ones: a saved monitor
    /// that is unplugged must not keep the monitors installed.
    private var isWanted: Bool {
        preferences.focusFollowsMouseEnabled
            && FocusDisplaySelection.hasConnectedMatch(
                saved: preferences.focusFollowsMouseDisplays, connected: Self.connectedDisplayKeys())
            && AXIsProcessTrusted()
    }

    static func connectedDisplayKeys() -> [String] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return PerDisplaySettings.key(for: CGDirectDisplayID(number.uint32Value))
        }
    }

    /// Runs only while it can do something: switched on, at least one display
    /// opted in, and Accessibility granted. Otherwise no monitor at all.
    private func sync() {
        isWanted ? install() : uninstall()
    }

    private func install() {
        guard mouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Drags are watched too, so the pause starts over once a drag ends
        // instead of firing the moment the button comes up.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            self?.recordMovement(to: point)
        }
        // The global monitor never sees the pointer over Wharf's own windows.
        // Moving into one cancels whatever was pending: nothing there is to
        // be raised. (The live pointer check before raising covers windows
        // that do not report mouse moves.)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.resetMovement()
            return event
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
        // Nothing still running may raise a window once the feature is off,
        // and a lookup not yet started never starts.
        workers.cancelAll()
        if let pending = lookup.inFlight { _ = lookup.settle(pending) }
        resetMovement()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        mouseMonitor = nil
        localMonitor = nil
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
        // One answer awaited at a time, and a free worker slot. A pending
        // rest waits (the timer keeps ticking) until the previous lookup
        // answers or is abandoned and a slot is free; nothing is queued.
        guard !lookup.isBusy, workers.canStart,
              let evaluation = state.nextEvaluation(
                at: ProcessInfo.processInfo.systemUptime,
                delayMilliseconds: preferences.focusFollowsMouseDelay)
        else { return }

        // `focus` below would put up a permission alert when Accessibility is
        // missing. A hover feature must never do that, so both the live answer
        // and the cached one have to agree first.
        guard AXIsProcessTrusted(), PermissionsService.shared.accessibility == .granted else {
            state.finishEvaluation(evaluation)
            return
        }

        // Everything here is window server and AppKit state: no app is asked
        // anything yet.
        let input = input(at: evaluation.point)
        let decision = HoverFocusGate.decide(input)
        let target: (windowID: CGWindowID, pid: pid_t)
        var needsFocusedWindow = false
        switch decision {
        case let .raise(windowID, pid):
            target = (windowID, pid)
        case .skip(.alreadyFocused) where input.focusedWindowID == nil:
            // Same app in front: which of its windows has focus needs
            // Accessibility, so the worker asks before deciding.
            guard let window = input.target else { state.finishEvaluation(evaluation); return }
            target = (window.windowID, window.ownerPID)
            needsFocusedWindow = true
        case .skip:
            state.finishEvaluation(evaluation)
            return
        }

        // The registry's snapshot usually has the window already, at no
        // Accessibility cost.
        let cachedElement = WindowRegistry.shared.windows.first {
            $0.processIdentifier == target.pid && $0.cgWindowID == target.windowID
        }.map { HoverAXElement(element: $0.element) }
        guard let job = workers.start() else { state.finishEvaluation(evaluation); return }
        let ticket = lookup.begin()
        // An absolute deadline on the monotonic clock, checked again when
        // the answer arrives (see `HoverCommitCheck.allowsCommit`).
        let deadline = ProcessInfo.processInfo.systemUptime + Self.lookupDeadline

        // The watchdog: a lookup still out at the deadline is abandoned and
        // told to stop, so a stalled app cannot hold up hover focus
        // everywhere else.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupDeadline) { [weak self] in
            guard let self, self.lookup.settle(ticket) else { return }
            self.workers.cancel(job)
            self.state.finishEvaluation(evaluation)
            self.startTimerIfNeeded()
        }

        let workers = self.workers
        worker.async { [weak self] in
            var element: HoverAXElement?
            var focusedWindowID: CGWindowID?
            // Every step first asks whether the answer is still wanted; a
            // job cancelled before it started does no Accessibility work.
            var raise = workers.shouldContinue(job)
            if raise, needsFocusedWindow {
                var focusedInput = input
                focusedWindowID = Self.focusedWindowID(of: target.pid)
                focusedInput.focusedWindowID = focusedWindowID
                if case .skip = HoverFocusGate.decide(focusedInput) { raise = false }
            }
            if raise, workers.shouldContinue(job) {
                // A fresh element gets the short timeout inside
                // `windowElement`, which also bounds the calls `focus` makes
                // with it. The cached one belongs to the registry and keeps
                // its own timeout.
                element = cachedElement ?? Self.windowElement(pid: target.pid, windowID: target.windowID) {
                    workers.shouldContinue(job)
                }
                // The raise on the main thread talks to this window again.
                // A window that does not answer here is left alone.
                if let found = element, !workers.shouldContinue(job) || !Self.isResponsive(found.element) {
                    element = nil
                }
            }
            // The slot is free the moment the Accessibility work ends, even
            // while the main thread is busy.
            workers.finish(job)
            let result = HoverLookupResult(element: element, focusedWindowID: focusedWindowID,
                                           usedRegistryElement: cachedElement != nil)
            DispatchQueue.main.async {
                self?.finishLookup(evaluation, ticket: ticket, deadline: deadline, target: target, result: result)
            }
        }
    }

    private func finishLookup(_ evaluation: HoverDwellEvaluation,
                              ticket: UInt64,
                              deadline: TimeInterval,
                              target: (windowID: CGWindowID, pid: pid_t),
                              result: HoverLookupResult) {
        // Already abandoned by the watchdog: the moment passed.
        guard lookup.settle(ticket) else { return }
        defer {
            state.finishEvaluation(evaluation)
            startTimerIfNeeded()
        }
        guard let element = result.element else { return }

        // Read everything fresh: the lookup took time.
        var check = HoverCommitCheck()
        check.now = ProcessInfo.processInfo.systemUptime
        check.deadline = deadline
        // The whole gate again, on what is true now: the app in front may
        // have become an excluded or full-screen one meanwhile, the lists
        // and displays may have changed.
        var fresh = input(at: evaluation.point)
        fresh.focusedWindowID = result.focusedWindowID
        check.freshDecision = HoverFocusGate.decide(fresh)
        check.featureActive = mouseMonitor != nil && isWanted
            && PermissionsService.shared.accessibility == .granted
        check.evaluationCurrent = state.isCurrent(evaluation)
        check.livePointer = Self.livePointer()
        check.receivingWindowID = check.livePointer.flatMap(Self.receivingWindow(at:))
        check.menuOpen = isMenuOpen(in: Self.onScreenWindows())
        check.buttonOrModifierHeld = Self.isButtonOrModifierHeld
        guard check.allowsCommit(of: target.windowID, pid: target.pid, restingAt: evaluation.point) else { return }

        // The window as the registry knows it now, not as it was when the
        // lookup began. One the registry has dropped since is not raised
        // through an element it handed out earlier.
        let registered = WindowRegistry.shared.windows.first {
            $0.processIdentifier == target.pid && $0.cgWindowID == target.windowID
        }
        if result.usedRegistryElement, registered == nil { return }
        let window = registered ?? AppWindow(
            element: element.element,
            bundleIdentifier: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier ?? "pid:\(target.pid)",
            processIdentifier: target.pid,
            appDisplayName: NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "",
            windowTitle: "",
            // On screen under the pointer, so not minimized.
            isMinimized: false,
            windowNumber: nil,
            cgWindowID: target.windowID,
            frame: nil
        )
        WindowRegistry.shared.focus(window)
    }

    private static var isButtonOrModifierHeld: Bool {
        NSEvent.pressedMouseButtons != 0
            || !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Everything the gate needs, read from the window server and AppKit.
    /// `point` is in global display coordinates, origin at the top left of
    /// the main display. `focusedWindowID` is left for the worker.
    private func input(at point: CGPoint) -> HoverFocusInput {
        var input = HoverFocusInput()
        input.ownPID = ProcessInfo.processInfo.processIdentifier
        input.mouseButtonsDown = NSEvent.pressedMouseButtons != 0
        input.modifiersHeld = !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        input.excludedBundleIDs = BundleIDList.matchSet(preferences.focusFollowsMouseExcludedBundleIDs)
        input.displayEnabled = isDisplayEnabled(at: point)

        let windows = Self.onScreenWindows()
        input.menuOpen = isMenuOpen(in: windows)
        input.target = HoverWindowScan.target(in: windows, at: point, pointerWindowID: Self.receivingWindow(at: point))

        if let target = input.target, let app = NSRunningApplication(processIdentifier: target.ownerPID) {
            input.targetBundleID = app.bundleIdentifier
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        input.frontmostPID = frontmost?.processIdentifier
        input.frontmostBundleID = frontmost?.bundleIdentifier
        input.frontmostIsFullScreen = HoverWindowScan.isFullScreen(
            pid: frontmost?.processIdentifier, in: windows, displayBounds: Self.displayBounds())
        return input
    }

    /// A menu of another app (window server list, owners that show menus:
    /// the frontmost app and background or accessory apps such as menu bar
    /// extras), or one of Wharf's own menus (menu tracking).
    private func isMenuOpen(in windows: [HoverWindowInfo]) -> Bool {
        if ownMenuDepth > 0 { return true }
        let workspace = NSWorkspace.shared
        var owners = Set(workspace.runningApplications
            .filter { $0.activationPolicy != .regular }
            .map { $0.processIdentifier })
        if let front = workspace.frontmostApplication?.processIdentifier { owners.insert(front) }
        return HoverWindowScan.isMenuOpen(
            in: windows, ownPID: ProcessInfo.processInfo.processIdentifier, menuOwnerPIDs: owners)
    }

    /// Every active display's bounds, top-left global coordinates.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static func onScreenWindows() -> [HoverWindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return raw.compactMap(HoverWindowScan.info(from:))
    }

    private func isDisplayEnabled(at point: CGPoint) -> Bool {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0,
              let key = PerDisplaySettings.key(for: displayID) else { return false }
        return preferences.focusFollowsMouseDisplays.contains(key)
    }

    /// The pointer now, in the same top-left global coordinates as the
    /// window server and the monitor's events.
    private static func livePointer() -> CGPoint? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: mainHeight - location.y)
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

    // MARK: - Worker queue only

    /// One position read, with whatever timeout the element carries.
    private nonisolated static func isResponsive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success
    }

    private nonisolated static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var windowID: CGWindowID = 0
        guard hoverAXWindowID(value as! AXUIElement, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// The app's Accessibility element for one window server window, read
    /// with a short timeout per message and a cap on how many windows are
    /// looked at.
    private nonisolated static func windowElement(pid: pid_t, windowID: CGWindowID,
                                                  shouldContinue: () -> Bool) -> HoverAXElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(
                app, kAXWindowsAttribute as CFString, 0, maximumWindowsScanned, &raw) == .success,
              let elements = raw as? [AXUIElement]
        else { return nil }
        // The same total budget as the registry's own enumeration.
        let deadline = DispatchTime.now() + .milliseconds(750)
        for element in elements {
            if DispatchTime.now() > deadline || !shouldContinue() { break }
            // Every element gets the short timeout before it is asked
            // anything, not only the match.
            AXUIElementSetMessagingTimeout(element, axTimeout)
            var id: CGWindowID = 0
            if hoverAXWindowID(element, &id) == .success, id == windowID {
                return HoverAXElement(element: element)
            }
        }
        return nil
    }
}
