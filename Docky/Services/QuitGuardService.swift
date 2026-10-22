//
//  QuitGuardService.swift
//  Wharf
//
//  Guards Command-Q and Command-W against a slip of the finger: per app (or
//  by default) the shortcut needs a hold, a second press, or an extra
//  modifier, with a small HUD saying what to do. Every other key passes
//  untouched, and a protected key is held back only while the protection
//  applies. The decisions live in QuitGuardStateMachine.
//
//  Fail safe throughout: the tap callback reads only cached state (the app
//  in front, the app that owns keyboard focus, the policy), never
//  Accessibility, and passes a key through when it has no answer. A confirmed action is bound to the app (and for Close,
//  the window) captured at the first press and checked again right before
//  it runs; if anything changed, or the targeted action fails, nothing
//  happens and the HUD says so. No shortcut is ever posted to whatever app
//  happens to be in front.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): QuitProtectionService's tap, the replay marker, and
//  quitting through a normal terminate request.
//

import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class QuitGuardService {
    static let shared = QuitGuardService()

    /// Set on events this service posts so its own tap lets them through.
    nonisolated static let syntheticMarker: Int64 = 0x5748_5147 // "WHQG"

    private struct FrontApp {
        let pid: pid_t
        let bundleIdentifier: String?
        let name: String
    }

    private struct Settings {
        var enabled = false
        var policy = QuitGuardPolicy(defaultMode: .off, overrides: [:], protectsQuit: false, protectsClose: false)
        var holdMilliseconds = 800.0
        var doublePressMilliseconds = 600.0
        var extraModifier = QuitGuardModifier.shift
    }

    private let preferences = WindowBehaviorPreferences.shared
    private var machine = QuitGuardStateMachine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables: Set<AnyCancellable> = []
    private var activationObserver: NSObjectProtocol?
    private var holdTimer: Timer?
    private var expiry: DispatchWorkItem?
    private var hudHide: DispatchWorkItem?
    /// The physical key each protected shortcut was last typed with, so the
    /// confirmed shortcut is sent with the same key.
    private var keyCodes: [QuitGuardKey: Int64] = [:]
    /// What the target app's focused window read as at the first press of a
    /// Close, by sequence. Read off the tap, right after it.
    private var capturedWindows: [Int: CapturedWindow] = [:]
    /// Cached so the tap callback never asks anything slow.
    private var frontmost: FrontApp?
    /// The app that owns keyboard focus by Accessibility, read off the tap
    /// and cached. Nil while unknown (just after an app switch, or when the
    /// read fails); only a known value that differs from `frontmost` makes
    /// the tap step aside, for a panel that takes keys without activating
    /// (Spotlight style) or an app switch the notification has not caught.
    private var focusedOwnerPid: pid_t?
    private var focusReadGeneration = 0
    private let focusQueue = DispatchQueue(label: "wharf.quitGuard.focus", qos: .userInteractive)
    /// The modifier that must still be down when a hold ends: Command, or
    /// Control when Windows keyboard translation turned Control-Q into
    /// Command-Q on the way in.
    private var holdModifier: CGEventFlags = .maskCommand
    private var settings = Settings()
    private let hud = QuitGuardHUD()
    private let status = WindowBehaviorStatus.shared
    private var started = false

    /// Recreating a tap macOS turned off for good: a few tries, further
    /// apart each time, then the pane says protection is inactive.
    private var retryCount = 0
    private var lastRetry = Date.distantPast
    private var retryWork: DispatchWorkItem?
    private static let maxRetries = 5

    private let messagingTimeout: Float = 0.3

    private struct CapturedWindow {
        let read: QuitGuardWindowRead
        let element: AXUIElement?
    }

    private init() {}

    /// Safe to call more than once: later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        observeChanges { [weak self] in
            let prefs = WindowBehaviorPreferences.shared
            let snapshot = Settings(
                enabled: prefs.quitGuardEnabled,
                policy: prefs.quitGuardPolicy,
                holdMilliseconds: prefs.quitGuardHoldMilliseconds,
                doublePressMilliseconds: prefs.quitGuardDoublePressMilliseconds,
                extraModifier: prefs.quitGuardExtraModifier
            )
            self?.settings = snapshot
            self?.syncTapState()
        }
        .store(in: &cancellables)

        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTapState() }
            .store(in: &cancellables)
    }

    private var isWanted: Bool {
        settings.enabled
            && (settings.policy.protectsQuit || settings.policy.protectsClose)
            && AXIsProcessTrusted()
    }

    private func syncTapState() {
        guard isWanted else {
            retryWork?.cancel()
            retryWork = nil
            retryCount = 0
            removeTap()
            status.quitGuardInactive = false
            return
        }
        // A tap macOS turned off and would not turn back on is rebuilt.
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            removeTap(keepingKeyState: true)
        }
        installTap()
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            status.quitGuardInactive = false
        } else {
            removeTap(keepingKeyState: true)
            scheduleRetry()
        }
    }

    /// The tap is dead: tear it down and build it again a little later.
    private func scheduleRetry() {
        // A death long after the last one starts a fresh count.
        if Date().timeIntervalSince(lastRetry) > 60 { retryCount = 0 }
        status.quitGuardInactive = true
        guard retryWork == nil else { return }
        guard retryCount < Self.maxRetries else {
            NSLog("[Wharf] Quit protection: the event tap keeps failing; protection is inactive")
            return
        }
        retryCount += 1
        lastRetry = Date()
        let delay = 0.5 * pow(2, Double(retryCount - 1))
        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.syncTapState()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // Appended at the tail, after every head inserted tap on the session,
        // so the Windows keyboard translation (a head inserted tap) has
        // already turned Control-W into Command-W by the time this sees it.
        // Head inserted taps run in reverse install order, which made the
        // old placement depend on which feature was switched on last; the
        // tail placement gives one fixed order: translate, then protect.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<QuitGuardService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Wharf] Quit protection: could not create the event tap")
            return
        }
        self.tap = tap
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(app) }
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        refreshFocusedOwner()
    }

    /// `keepingKeyState` is for a rebuild: keys already held back stay owned
    /// (the machine forgets them on its own timeout), so a repeat cannot
    /// slip through once the new tap is up.
    private func removeTap(keepingKeyState: Bool = false) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        tap = nil
        runLoopSource = nil
        frontmost = nil
        focusedOwnerPid = nil
        if keepingKeyState { machine.interrupted() } else { machine.reset() }
        capturedWindows.removeAll()
        clearTimers()
        hideHUD()
    }

    /// Reads which app owns keyboard focus, off the main thread, and caches
    /// it. A newer read, or an app switch, makes an older answer stale.
    private func refreshFocusedOwner() {
        focusReadGeneration += 1
        let generation = focusReadGeneration
        let timeout = messagingTimeout
        focusQueue.async { [weak self] in
            let pid = Self.systemFocusedAppPid(timeout: timeout)
            DispatchQueue.main.async {
                guard let self, self.focusReadGeneration == generation else { return }
                self.focusedOwnerPid = pid
            }
        }
    }

    nonisolated private static func systemFocusedAppPid(timeout: Float) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else {
            frontmost = nil
            return
        }
        frontmost = FrontApp(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? "the app"
        )
    }

    /// A different app in front ends any wait that belongs to another app.
    private func frontmostChanged(_ app: NSRunningApplication?) {
        updateFrontmost(app)
        // The cached focus owner predates the switch: unknown until reread.
        focusedOwnerPid = nil
        refreshFocusedOwner()
        let decision = machine.frontmostChanged(to: frontmost?.pid ?? 0)
        if decision == .cancel {
            clearTimers()
            capturedWindows.removeAll()
            hideHUD()
        }
    }

    // MARK: - Event routing

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Keys may have been missed, including the release that ends a
            // swallow. The wait ends, but held keys stay owned and a repeat
            // of a protected shortcut is still swallowed (see interrupted()).
            machine.interrupted()
            capturedWindows.removeAll()
            clearTimers()
            hideHUD()
            if let tap, settings.enabled {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    // Never torn down from inside its own callback.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.removeTap(keepingKeyState: true)
                        self.scheduleRetry()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        // Wharf's own window switcher uses Q and W under the Command chord to
        // act on its selection; those keys belong to it while it is open.
        if WindowSwitcherService.shared.isPresented, !machine.hasPressInFlight {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown:
            // Ordinary typing stops here, before any lookup.
            guard flags.contains(.maskCommand) || machine.hasPressInFlight else {
                return Unmanaged.passUnretained(event)
            }
            // The character only classifies the shortcut; everything after
            // this follows the physical key.
            let key = QuitGuardKey.matching(
                character: NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
                keyCode: keyCode
            )
            let front = frontmost
            // Keys going to something other than the app in front (a panel
            // that does not activate, or an app switch not yet announced)
            // are not that app's shortcut: protect nothing.
            let focusAgrees = focusedOwnerPid == nil || focusedOwnerPid == front?.pid
            // No trustworthy answer for the app in front: protect nothing.
            let mode = key.flatMap { key in
                front.map { settings.policy.mode(for: $0.bundleIdentifier, key: key) }
            }.flatMap { focusAgrees ? $0 : nil } ?? .off
            machine.holdMilliseconds = settings.holdMilliseconds
            machine.doublePressMilliseconds = settings.doublePressMilliseconds
            machine.extraModifier = settings.extraModifier
            let decision = machine.keyDown(
                key: key,
                keyCode: keyCode,
                modifiers: QuitGuardModifiers(
                    command: flags.contains(.maskCommand),
                    shift: flags.contains(.maskShift),
                    option: flags.contains(.maskAlternate),
                    control: flags.contains(.maskControl)
                ),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                timestamp: event.timestamp,
                mode: mode,
                target: front?.pid ?? 0
            )
            if let key, decision != .pass, decision != .swallow { keyCodes[key] = keyCode }
            if case .beginHold = decision {
                // Physical Command means a real Command-Q; otherwise the
                // Windows keyboard translation made it from Control.
                holdModifier = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
                    ? .maskCommand : .maskControl
            }
            return apply(decision, to: event, app: front)

        case .keyUp:
            guard machine.hasPressInFlight else { return Unmanaged.passUnretained(event) }
            return apply(machine.keyUp(keyCode: keyCode, timestamp: event.timestamp), to: event, app: nil)

        case .flagsChanged:
            // Command going down is the moment to check who has focus, well
            // before the Q or W that may follow.
            if flags.contains(.maskCommand) { refreshFocusedOwner() }
            _ = apply(machine.commandChanged(isHeld: flags.contains(.maskCommand)), to: event, app: nil)
            // Modifier changes always reach the system.
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func apply(
        _ decision: QuitGuardStateMachine.Decision,
        to event: CGEvent,
        app: FrontApp?
    ) -> Unmanaged<CGEvent>? {
        let name = app?.name ?? "the app"
        switch decision {
        case .pass:
            // A failure note (hudHide scheduled) stays up for its full time,
            // even as the user lets go of Command.
            if machine.pending == nil, hudHide == nil {
                clearTimers()
                hideHUD()
            }
            return Unmanaged.passUnretained(event)

        case .swallow:
            return nil

        case .beginHold(let key):
            clearTimers()
            let sequence = machine.pending?.sequence ?? 0
            let heldKeyCode = machine.pending?.keyCode
            let modifier = holdModifier
            captureWindowIfClose(key, sequence: sequence, pid: app?.pid)
            let seconds = machine.holdMilliseconds / 1_000
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Time alone never confirms: the key and the modifier must
                    // still be down now, in case their release went unseen.
                    let keyDown = heldKeyCode.map {
                        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
                    } ?? false
                    let modifierDown = CGEventSource.flagsState(.combinedSessionState).contains(modifier)
                    self.carryOut(
                        self.machine.holdElapsed(sequence: sequence, keyStillDown: keyDown, commandStillDown: modifierDown),
                        name: name
                    )
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            showHUD("Keep holding \(key.symbol) to \(Self.verb(for: key)) \(name)", holdSeconds: seconds, pid: app?.pid)
            return nil

        case .beginDoublePress(let key):
            captureWindowIfClose(key, sequence: machine.pending?.sequence ?? 0, pid: app?.pid)
            scheduleExpiry(after: machine.doublePressMilliseconds / 1_000 + 0.1)
            showHUD("Press \(key.symbol) again to \(Self.verb(for: key)) \(name)", holdSeconds: nil, pid: app?.pid)
            return nil

        case .showModifierHint(let key, let modifier):
            scheduleExpiry(after: QuitGuardStateMachine.modifierHintSeconds)
            showHUD("Press \(modifier.symbol)\(key.symbol) to \(Self.verb(for: key)) \(name)", holdSeconds: nil, pid: app?.pid)
            return nil

        case .confirm, .cancel:
            carryOut(decision, name: name)
            return nil
        }
    }

    /// Acts on a timer or key decision: confirm runs the shortcut for its
    /// target only, cancel just clears the HUD.
    private func carryOut(_ decision: QuitGuardStateMachine.Decision, name: String) {
        switch decision {
        case .confirm(let key, let target):
            clearTimers()
            hideHUD()
            let keyCode = keyCodes[key] ?? key.fallbackKeyCode
            // A capture that never answered counts as unreadable.
            let captured: CapturedWindow? = machine.confirmedSequence.map {
                capturedWindows[$0] ?? CapturedWindow(read: .unreadable, element: nil)
            }
            capturedWindows.removeAll()
            // Out of the tap callback first, so nothing slow runs inside it.
            DispatchQueue.main.async { [weak self] in
                self?.perform(key, target: target, name: name, keyCode: keyCode, capturedWindow: captured)
            }
        case .cancel:
            clearTimers()
            capturedWindows.removeAll()
            hideHUD()
        case .pass, .swallow, .beginHold, .beginDoublePress, .showModifierHint:
            break
        }
    }

    /// `captured` is nil for a one-press confirm (nothing was captured, the
    /// press itself is the confirmation).
    private func perform(_ key: QuitGuardKey, target: pid_t, name: String, keyCode: Int64, capturedWindow captured: CapturedWindow?) {
        // Revalidate right before acting: the target must still be running,
        // still be the app in front, and (when Accessibility can say) still
        // own keyboard focus.
        let focusOwner = Self.systemFocusedAppPid(timeout: messagingTimeout)
        guard target > 0,
              let app = NSRunningApplication(processIdentifier: target),
              !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
              focusOwner == nil || focusOwner == target
        else {
            flashHUD("\(name) is no longer in front, so nothing happened", pid: target)
            return
        }

        switch key {
        case .quit:
            // A normal quit request; the app may still ask to save. When it
            // refuses, nothing else is tried.
            if !app.terminate() {
                flashHUD("Could not ask \(name) to quit", pid: target)
            }

        case .close:
            let current = Self.focusedWindow(of: target, timeout: messagingTimeout)
            let sameWindow: Bool = {
                guard let a = captured?.element, let b = current.element else { return false }
                return CFEqual(a, b)
            }()
            switch QuitGuardCloseCheck.verdict(captured: captured?.read, current: current.read, sameWindow: sameWindow) {
            case .noWindow:
                flashHUD("\(name) has no window in front, so nothing was closed", pid: target)
                return
            case .windowChanged:
                flashHUD("The window changed, so nothing was closed", pid: target)
                return
            case .post:
                break
            }
            // Command-W goes to the captured app only, never to whatever is
            // in front. The keystroke (not the close button) keeps the app's
            // own meaning: a tab in a browser, a window elsewhere.
            let before = Self.closeSnapshot(of: target, window: current.element, timeout: messagingTimeout)
            Self.postCommandPress(keyCode: keyCode, to: target)
            // Nothing tells Wharf whether the app acted on the key, so look
            // shortly after: a window or tab gone, or a save sheet, is enough.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                let after = Self.closeSnapshot(of: target, window: current.element, timeout: self.messagingTimeout)
                if !QuitGuardCloseCheck.looksHandled(before: before, after: after) {
                    self.flashHUD("Sent \(QuitGuardKey.close.symbol) to \(name), but could not confirm anything closed", pid: target)
                }
            }
        }
    }

    private func captureWindowIfClose(_ key: QuitGuardKey, sequence: Int, pid: pid_t?) {
        guard key == .close else { return }
        capturedWindows.removeAll()
        guard let pid, pid > 0 else { return }
        // Accessibility is never asked inside the tap; the read happens on
        // the next turn of the main loop, well before any confirm.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.machine.pending?.sequence == sequence else { return }
            let read = Self.focusedWindow(of: pid, timeout: self.messagingTimeout)
            self.capturedWindows[sequence] = CapturedWindow(read: read.read, element: read.element)
        }
    }

    /// The app's focused window, told apart from "the app says it has none"
    /// and "the app cannot be asked".
    private static func focusedWindow(of pid: pid_t, timeout: Float) -> (read: QuitGuardWindowRead, element: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (.noFocusedWindow, nil) }
            return (.window, (value as! AXUIElement))
        case .noValue:
            return (.noFocusedWindow, nil)
        default:
            return (.unreadable, nil)
        }
    }

    private static func closeSnapshot(of pid: pid_t, window: AXUIElement?, timeout: Float) -> QuitGuardCloseCheck.Snapshot {
        var snapshot = QuitGuardCloseCheck.Snapshot()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success {
            snapshot.windowCount = count
        }
        if let window {
            AXUIElementSetMessagingTimeout(window, timeout)
            var title: CFTypeRef?
            switch AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) {
            case .success:
                snapshot.windowExists = true
                snapshot.windowTitle = title as? String
            case .invalidUIElement:
                snapshot.windowExists = false
            default:
                break
            }
            let focused = focusedWindow(of: pid, timeout: timeout)
            if focused.read != .unreadable {
                snapshot.focusedIsSameWindow = focused.element.map { CFEqual($0, window) } ?? false
            }
        }
        return snapshot
    }

    private func scheduleExpiry(after seconds: Double) {
        clearTimers()
        let sequence = machine.pending?.sequence ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.carryOut(self.machine.expired(sequence: sequence), name: "")
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearTimers() {
        holdTimer?.invalidate()
        holdTimer = nil
        expiry?.cancel()
        expiry = nil
    }

    // MARK: - HUD, always off the tap callback

    /// `pid` is the app the message is about; the HUD goes on the screen
    /// with that app's front window.
    private func showHUD(_ message: String, holdSeconds: Double?, pid: pid_t?) {
        hudHide?.cancel()
        hudHide = nil
        DispatchQueue.main.async { [weak self] in self?.hud.show(message: message, holdSeconds: holdSeconds, pid: pid) }
    }

    private func hideHUD() {
        hudHide?.cancel()
        hudHide = nil
        DispatchQueue.main.async { [weak self] in self?.hud.hide() }
    }

    /// A short note when a confirmed action was not carried out.
    private func flashHUD(_ message: String, pid: pid_t?) {
        showHUD(message, holdSeconds: nil, pid: pid)
        let work = DispatchWorkItem { [weak self] in
            self?.hudHide = nil
            self?.hud.hide()
        }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Posts a plain Command press of `keyCode` straight to `pid`, marked so
    /// this tap lets it through. The extra modifier, if one confirmed it, is
    /// left off.
    private static func postCommandPress(keyCode: Int64, to pid: pid_t) {
        for isDown in [true, false] {
            guard let copy = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
            copy.flags = .maskCommand
            copy.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            copy.postToPid(pid)
        }
    }

    private static func verb(for key: QuitGuardKey) -> String {
        key == .quit ? "quit" : "close a window in"
    }
}

// MARK: - HUD

/// A small panel near the bottom of the screen that shows the target app's
/// front window (the pointer's screen when that cannot be found). It never
/// takes focus or clicks.
final class QuitGuardHUD {
    static let width: CGFloat = 360
    private var panel: NSPanel?
    private let model = QuitGuardHUDModel()

    func show(message: String, holdSeconds: Double?, pid: pid_t?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.message = message
        model.holdSeconds = holdSeconds
        model.startedAt = Date()

        // Long app names wrap; the panel grows to fit. Measured directly,
        // since the hosting view lays out the new text only later.
        let textHeight = (message as NSString).boundingRect(
            with: NSSize(width: Self.width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        ).height
        let extra: CGFloat = holdSeconds == nil ? 24 : 42
        let size = NSSize(width: Self.width, height: max(holdSeconds == nil ? 52 : 70, ceil(textHeight) + extra))
        let screen = pid.flatMap(Self.screen(ofFrontWindowOf:))
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18,
                       width: size.width, height: size.height),
                display: true
            )
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The screen holding most of the app's frontmost normal window, from
    /// the window server list (front to back, no Accessibility).
    private static func screen(ofFrontWindowOf pid: pid_t) -> NSScreen? {
        guard pid > 0,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = TrafficLightHitTest.bounds(from: window),
                  bounds.width >= 50, bounds.height >= 50
            else { continue }
            // Window server bounds are top down from the primary screen.
            let flipped = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return NSScreen.screens.max { a, b in
                area(a.frame.intersection(flipped)) < area(b.frame.intersection(flipped))
            }.flatMap { area($0.frame.intersection(flipped)) > 0 ? $0 : nil }
        }
        return nil
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: QuitGuardHUDView(model: model))
        return panel
    }
}

@Observable
final class QuitGuardHUDModel {
    var message = ""
    var holdSeconds: Double?
    var startedAt = Date()
}

private struct QuitGuardHUDView: View {
    let model: QuitGuardHUDModel

    var body: some View {
        VStack(spacing: 8) {
            Text(model.message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: QuitGuardHUD.width - 32)
            if let seconds = model.holdSeconds {
                TimelineView(.animation) { context in
                    ProgressView(value: min(1, context.date.timeIntervalSince(model.startedAt) / seconds))
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
