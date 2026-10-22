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
//  When Wharf ends up doing nothing with a click it held back (the check
//  failed, the button is disabled, the move failed), the press and release
//  are handed back to the app: a held click is never dropped.
//
//  Threads: the tap and the decisions run on main. Accessibility questions
//  this file asks itself (the lookup, the hit test, the enabled and sheet
//  checks, the window frame) run on a queue per app, each element bounded by
//  a short messaging timeout, so one hung app holds up neither main nor the
//  other apps. Focus, full screen and the snap move go through
//  WindowRegistry and WindowSnapService, which are main actor services; those
//  calls stay on main.
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
    private var holdWork: DispatchWorkItem?
    /// Counts real presses, so a click handed back late never lands after a
    /// newer press the app already has.
    private var pressSerial = 0
    /// A press passed to the app was dragged: probably a window move, after
    /// which the cache is refilled where the pointer let go.
    private var sawPassedDrag = false

    private var cache: [CGWindowID: ZoomTarget] = [:]
    private var fillsInFlight: Set<CGWindowID> = []
    /// Frames of the ordinary windows on screen at the last pointer move. A
    /// press outside every one of their button areas skips the window list.
    private var titleBarFrames: [CGRect] = []
    private var moveThrottle = GreenButtonMoveThrottle(interval: 0.08)
    private var trailingMove: DispatchWorkItem?
    private var lookUpQueues: [pid_t: DispatchQueue] = [:]
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

        /// The same answer for the window at its new place.
        func moved(to bounds: CGRect, rightToLeft: Bool) -> ZoomTarget {
            ZoomTarget(
                pid: pid, windowID: windowID, bundleIdentifier: bundleIdentifier, windowBounds: bounds,
                buttonFrame: GreenButtonLogic.shiftedButton(buttonFrame, from: windowBounds, to: bounds, rightToLeft: rightToLeft),
                button: button, greenButtons: greenButtons, allowsNativeFallback: allowsNativeFallback,
                isUsable: isUsable, filledAt: Date()
            )
        }
    }

    private struct PendingClick {
        let token: Int
        let serial: Int
        let target: ZoomTarget
        let point: CGPoint
        let action: GreenButtonAction
        let press: CGEvent
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
        trailingMove?.cancel()
        trailingMove = nil
        interrupt()
        cache.removeAll()
        titleBarFrames = []
    }

    /// Events may have passed unseen: forget the held press so its release
    /// goes through, and drop the pending action.
    private func interrupt() {
        pair.interrupted()
        sawPassedDrag = false
        clearPending()
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
            pressSerial += 1
            pair.pressPassed()
            clearPending()
            sawPassedDrag = false
            let flags = event.flags
            let action = GreenButtonLogic.action(
                command: flags.contains(.maskCommand),
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate),
                shift: flags.contains(.maskShift)
            )
            guard action != .passThrough,
                  let target = cachedTarget(at: event.location),
                  let press = event.copy()
            else { return Unmanaged.passUnretained(event) }

            let token = pair.pressSwallowed()
            pendingClick = PendingClick(
                token: token, serial: pressSerial, target: target, point: event.location, action: action, press: press
            )
            let work = DispatchWorkItem { [weak self] in self?.holdElapsed(token: token) }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + GreenButtonPairTracker.holdSeconds, execute: work)
            return nil

        case .leftMouseDragged:
            if pair.dragged() == .swallow { return nil }
            sawPassedDrag = true
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            let inside = pendingClick.map {
                $0.target.buttonFrame.insetBy(dx: -mouseUpTolerance, dy: -mouseUpTolerance).contains(event.location)
            } ?? false
            switch pair.released(insideButton: inside) {
            case .pass, .replayPress:
                if sawPassedDrag {
                    // A window drag may have just ended: look up the window
                    // under the pointer again, after the release is out.
                    sawPassedDrag = false
                    let point = event.location
                    DispatchQueue.main.async { [weak self] in self?.refreshCache(at: point, wholeWindow: true) }
                }
                return Unmanaged.passUnretained(event)
            case .swallow:
                // Released away from the button: cancelled, as it is natively.
                clearPending()
                return nil
            case .perform(let token):
                if let click = pendingClick, click.token == token {
                    let release = event.copy()
                    DispatchQueue.main.async { [weak self] in self?.perform(click, release: release) }
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
    /// button itself. No Accessibility, and the window list is read only
    /// when a cached button is under the point.
    private func cachedTarget(at point: CGPoint) -> ZoomTarget? {
        let now = Date()
        guard cache.values.contains(where: {
            $0.isUsable && $0.buttonFrame.contains(point) && now.timeIntervalSince($0.filledAt) < cacheLifetime
        }) else {
            // Nothing cached here. If the press is near a title bar, look the
            // window up once the press is on its way, for the next click.
            if TrafficLightHitTest.mayHit(point, frames: titleBarFrames, button: .zoom, rightToLeft: rightToLeft) {
                DispatchQueue.main.async { [weak self] in self?.refreshCache(at: point, wholeWindow: false) }
            }
            return nil
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let candidate = TrafficLightHitTest.candidate(
            in: windows, at: point, button: .zoom, ownProcessID: getpid(), rightToLeft: rightToLeft
        ) else { return nil }
        guard let target = cache[candidate.windowID],
              target.isUsable,
              target.pid == candidate.pid,
              Self.sameRect(target.windowBounds, candidate.frame),
              now.timeIntervalSince(target.filledAt) < cacheLifetime,
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
        if let press = pendingClick?.press {
            press.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            press.post(tap: .cghidEventTap)
        }
        clearPending()
    }

    private func clearPending() {
        pendingClick = nil
        holdWork?.cancel()
        holdWork = nil
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: - Looking the button up ahead of time

    /// Throttled, keeping the last move of a burst so the lookup also runs
    /// where the pointer came to rest.
    private func pointerMoved() {
        switch moveThrottle.moved(at: ProcessInfo.processInfo.systemUptime) {
        case .runNow:
            trailingMove?.cancel()
            trailingMove = nil
            refreshAtPointer()
        case .runAfter(let delay):
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.trailingMove = nil
                self.moveThrottle.trailingRan(at: ProcessInfo.processInfo.systemUptime)
                self.refreshAtPointer()
            }
            trailingMove = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .alreadyScheduled:
            break
        }
    }

    private func refreshAtPointer() {
        guard tap != nil, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let mouse = NSEvent.mouseLocation
        refreshCache(at: CGPoint(x: mouse.x, y: primaryHeight - mouse.y), wholeWindow: false)
    }

    /// Reads the window list once, keeps the title bar frames for the tap's
    /// prefilter, and looks up the window in front at `point` when the cache
    /// has no fresh answer for it. `wholeWindow` looks it up wherever the
    /// point is in the window, not only on its green button (after a drag).
    private func refreshCache(at point: CGPoint, wholeWindow: Bool) {
        guard tap != nil else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let ownPID = getpid()
        titleBarFrames = TrafficLightHitTest.titleBarWindowFrames(in: windows, ownProcessID: ownPID)
        let found = wholeWindow
            ? TrafficLightHitTest.frontWindow(in: windows, at: point, ownProcessID: ownPID)
            : TrafficLightHitTest.candidate(in: windows, at: point, button: .zoom, ownProcessID: ownPID, rightToLeft: rightToLeft)
        guard let candidate = found else { return }
        if let cached = cache[candidate.windowID],
           Self.sameRect(cached.windowBounds, candidate.frame),
           Date().timeIntervalSince(cached.filledAt) < cacheLifetime {
            return
        }
        scheduleFill(candidate)
    }

    /// Looks the green button up on its app's own queue, so an app that
    /// answers Accessibility slowly (or not at all) holds up neither the main
    /// thread, where both input taps run, nor the lookups for other apps.
    /// Only the cache write comes back to main.
    private func scheduleFill(_ candidate: TrafficLightCandidate) {
        guard tap != nil, fillsInFlight.insert(candidate.windowID).inserted else { return }
        let bundleIdentifier = NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier
        if WindowBehaviorBundleList.contains(bundleIdentifier, in: preferences.maximizeExceptions) {
            fillsInFlight.remove(candidate.windowID)
            store(nil, for: candidate, bundleIdentifier: bundleIdentifier)
            return
        }
        lookUpQueue(for: candidate.pid).async { [weak self] in
            let found = Self.lookUp(pid: candidate.pid, windowID: candidate.windowID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fillsInFlight.remove(candidate.windowID)
                guard self.tap != nil else { return }
                self.store(found, for: candidate, bundleIdentifier: bundleIdentifier)
            }
        }
    }

    private func lookUpQueue(for pid: pid_t) -> DispatchQueue {
        if let queue = lookUpQueues[pid] { return queue }
        if lookUpQueues.count > 32 {
            // Work already queued keeps its queue alive; only the map resets.
            lookUpQueues.removeAll()
        }
        let queue = DispatchQueue(label: "wharf.greenButton.lookUp.\(pid)", qos: .userInitiated)
        lookUpQueues[pid] = queue
        return queue
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

    /// After Wharf moved a window, its cached answer follows it at once, so
    /// a quick second click (to put it back) is still Wharf's and does not
    /// reach the app's own full screen. A fresh lookup then confirms it.
    private func followMove(of target: ZoomTarget) {
        guard tap != nil,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], target.windowID) as? [[String: Any]])?.first,
              let bounds = TrafficLightHitTest.bounds(from: info)
        else { return }
        let current = cache[target.windowID] ?? target
        if current.isUsable, !Self.sameRect(current.windowBounds, bounds) {
            cache[target.windowID] = current.moved(to: bounds, rightToLeft: rightToLeft)
        }
        scheduleFill(TrafficLightCandidate(pid: target.pid, windowID: target.windowID, frame: bounds))
    }

    nonisolated private struct LookUp {
        let button: AXUIElement
        let all: [AXUIElement]
        let frame: CGRect
        let allowsNativeFallback: Bool
    }

    /// The green button of one window, or nil for a window to leave alone
    /// (not found, full screen, no enabled button). Runs on a lookup queue.
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

    /// What the checks right before acting found, read on the app's lookup
    /// queue.
    nonisolated private enum Preflight {
        /// The press did not land on the green button after all.
        case missed
        /// The button is disabled, or a sheet or modal panel blocks the
        /// window: the app decides what the click does.
        case blocked
        case clear(isMainWindow: Bool, frame: CGRect?)
    }

    private func perform(_ click: PendingClick, release: CGEvent?) {
        guard let button = click.target.button else {
            replay(click, release: release)
            return
        }
        let target = click.target
        let point = click.point
        lookUpQueue(for: target.pid).async { [weak self] in
            let preflight = Self.preflight(pid: target.pid, windowID: target.windowID, button: button, greenButtons: target.greenButtons, at: point)
            DispatchQueue.main.async { self?.act(on: click, release: release, preflight: preflight) }
        }
    }

    private func act(on click: PendingClick, release: CGEvent?, preflight: Preflight) {
        let isMainWindow: Bool
        let axFrame: CGRect?
        switch preflight {
        case .missed:
            // The window changed under the click: forget the answer and give
            // the click to whatever is there now.
            cache[click.target.windowID] = nil
            replay(click, release: release)
            return
        case .blocked:
            replay(click, release: release)
            return
        case .clear(let main, let frame):
            isMainWindow = main
            axFrame = frame
        }

        let registry = WindowRegistry.shared
        guard let window = registry.liveWindows(for: click.target.pid)
                .first(where: { $0.cgWindowID == click.target.windowID })
        else {
            if !pressNatively(click) { replay(click, release: release) }
            return
        }

        // A green button click on a window behind others brings it forward,
        // as a click on any part of a window does, also when its app is
        // already in front.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != click.target.pid || !isMainWindow {
            registry.focus(window)
        }

        let handled: Bool
        switch click.action {
        case .passThrough:
            handled = false
        case .nativeFullScreen:
            // Option asked for the real full screen, so pressing either kind
            // of green button is fine here.
            if registry.setFullscreen(window, fullscreen: true) {
                handled = true
            } else if let button = click.target.button {
                handled = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            } else {
                handled = false
            }
        case .toggleMaximize:
            let snap = WindowSnapService.shared
            if isMaximized(window, axFrame: axFrame) {
                // Nothing to restore (maximized some other way): the click
                // goes back to the app, as if Wharf were not there.
                handled = snap.perform(.restore, on: window)
            } else {
                handled = snap.perform(.maximize, on: window) || pressNatively(click)
            }
        }

        guard handled else {
            replay(click, release: release)
            return
        }
        // The window moved: keep its answer in step right away, and again
        // once any animation has settled.
        let target = click.target
        followMove(of: target)
        for delay in [0.15, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.followMove(of: target) }
        }
    }

    /// Hands a held back click to the app, press then release, marked so the
    /// tap lets both by. Skipped when the user has pressed again since: the
    /// old click would land inside the newer one and split its pair.
    private func replay(_ click: PendingClick, release: CGEvent?) {
        guard click.serial == pressSerial else {
            NSLog("[Wharf] Green button maximize: a newer press arrived; the held click was not handed back")
            return
        }
        let up = release ?? CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: click.point, mouseButton: .left
        )
        click.press.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        click.press.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Whether the window already sits on the Maximize rectangle. Worked out
    /// here rather than by calling Maximize, which would record the maximized
    /// frame as the one to restore. `axFrame` is the frame the preflight read
    /// off main; the registry is asked only when that read failed.
    private func isMaximized(_ window: AppWindow, axFrame: CGRect?) -> Bool {
        guard let axFrame = axFrame ?? WindowRegistry.shared.liveFrame(of: window) ?? window.frame,
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

    /// Presses the classic zoom button for the app. False when there is no
    /// such button or the press failed.
    private func pressNatively(_ click: PendingClick) -> Bool {
        guard click.target.allowsNativeFallback, let button = click.target.button else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: - Accessibility helpers (never called from the tap)

    /// The checks right before acting: the click is on the green button, the
    /// button is still enabled, and no sheet or modal panel blocks the
    /// window. Runs on the app's lookup queue.
    nonisolated private static func preflight(
        pid: pid_t,
        windowID: CGWindowID,
        button: AXUIElement,
        greenButtons: [AXUIElement],
        at point: CGPoint
    ) -> Preflight {
        // The app scoped hit test below cannot see another app's window
        // that came in front since the press; the window server can.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard TrafficLightHitTest.frontWindow(in: windows, at: point, ownProcessID: getpid())?.windowID == windowID,
              hitIsOnButton(pid: pid, buttons: greenButtons, at: point)
        else { return .missed }
        guard boolAttribute(button, kAXEnabledAttribute as String, default: true) else { return .blocked }
        let window = elementAttribute(button, kAXWindowAttribute as String)
        if let window, hasSheet(window) { return .blocked }
        if GreenButtonLogic.hasModalPanel(in: windows, pid: pid) { return .blocked }
        let isMain = window.map { boolAttribute($0, kAXMainAttribute as String) } ?? false
        return .clear(isMainWindow: isMain, frame: window.flatMap { frame(of: $0) })
    }

    /// The element Accessibility finds at `point` must be one of the cached
    /// green button elements itself or something inside it. A nearby title
    /// bar does not count. Asked of the app's own element, whose timeout is
    /// set here: setting one on the system wide element would change the
    /// default for every element in Wharf.
    nonisolated private static func hitIsOnButton(pid: pid_t, buttons: [AXUIElement], at point: CGPoint) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit
        else { return false }
        AXUIElementSetMessagingTimeout(current, messagingTimeout)
        for _ in 0..<4 {
            if buttons.contains(where: { CFEqual(current, $0) }) { return true }
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else { return false }
            current = parent
        }
        return false
    }

    /// Whether a sheet is attached to the window. Only the first few dozen
    /// children are asked, each bounded by the timeout.
    nonisolated private static func hasSheet(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return false }
        for child in children.prefix(40) {
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == kAXSheetRole as String {
                return true
            }
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
            // the timeout per window, on its own lookup queue.
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success, id == windowID {
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
