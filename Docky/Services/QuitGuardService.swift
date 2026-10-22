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
//  in front, the policy), never Accessibility, and passes a key through when
//  it has no answer. A confirmed action is bound to the app (and for Close,
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
    /// The focused window of the target app at the first press of a Close,
    /// by sequence. Read off the tap, right after it.
    private var capturedWindows: [Int: AXUIElement] = [:]
    /// Cached so the tap callback never asks anything slow.
    private var frontmost: FrontApp?
    private var settings = Settings()
    private let hud = QuitGuardHUD()

    private let messagingTimeout: Float = 0.3

    private init() {}

    func start() {
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

    private func syncTapState() {
        let wanted = settings.enabled
            && (settings.policy.protectsQuit || settings.policy.protectsClose)
            && AXIsProcessTrusted()
        if wanted { installTap() } else { removeTap() }
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
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        tap = nil
        runLoopSource = nil
        frontmost = nil
        machine.reset()
        capturedWindows.removeAll()
        clearTimers()
        hideHUD()
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
            // Keys may have been missed, including the release that ends a swallow.
            machine.reset()
            capturedWindows.removeAll()
            clearTimers()
            hideHUD()
            if let tap, settings.enabled { CGEvent.tapEnable(tap: tap, enable: true) }
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
            // No trustworthy answer for the app in front: protect nothing.
            let mode = key.flatMap { key in
                front.map { settings.policy.mode(for: $0.bundleIdentifier, key: key) }
            } ?? .off
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
            return apply(decision, to: event, app: front)

        case .keyUp:
            guard machine.hasPressInFlight else { return Unmanaged.passUnretained(event) }
            return apply(machine.keyUp(keyCode: keyCode), to: event, app: nil)

        case .flagsChanged:
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
            if machine.pending == nil {
                clearTimers()
                hideHUD()
            }
            return Unmanaged.passUnretained(event)

        case .swallow:
            return nil

        case .beginHold(let key):
            clearTimers()
            let sequence = machine.pending?.sequence ?? 0
            captureWindowIfClose(key, sequence: sequence, pid: app?.pid)
            let seconds = machine.holdMilliseconds / 1_000
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.carryOut(self.machine.holdElapsed(sequence: sequence), name: name)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            showHUD("Keep holding \(key.symbol) to \(Self.verb(for: key)) \(name)", holdSeconds: seconds)
            return nil

        case .beginDoublePress(let key):
            captureWindowIfClose(key, sequence: machine.pending?.sequence ?? 0, pid: app?.pid)
            scheduleExpiry(after: machine.doublePressMilliseconds / 1_000 + 0.1)
            showHUD("Press \(key.symbol) again to \(Self.verb(for: key)) \(name)", holdSeconds: nil)
            return nil

        case .showModifierHint(let key, let modifier):
            scheduleExpiry(after: QuitGuardStateMachine.modifierHintSeconds)
            showHUD("Press \(modifier.symbol)\(key.symbol) to \(Self.verb(for: key)) \(name)", holdSeconds: nil)
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
            let captured = machine.confirmedSequence.map { capturedWindows[$0] }
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

    /// `capturedWindow` is nil for a one-press confirm (nothing was captured,
    /// the press itself is the confirmation), and `.some(nil)` when a capture
    /// was expected but could not be read: then nothing is closed.
    private func perform(_ key: QuitGuardKey, target: pid_t, name: String, keyCode: Int64, capturedWindow: AXUIElement??) {
        // Revalidate right before acting: the target must still be running
        // and still be the app in front.
        guard target > 0,
              let app = NSRunningApplication(processIdentifier: target),
              !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target
        else {
            flashHUD("\(name) is no longer in front, so nothing happened")
            return
        }

        switch key {
        case .quit:
            // A normal quit request; the app may still ask to save. When it
            // refuses, nothing else is tried.
            if !app.terminate() {
                flashHUD("Could not ask \(name) to quit")
            }

        case .close:
            guard let current = Self.focusedWindow(of: target, timeout: messagingTimeout) else {
                flashHUD("Could not find the window in \(name), so nothing was closed")
                return
            }
            if let capturedWindow {
                guard let capturedWindow, CFEqual(capturedWindow, current) else {
                    flashHUD("The window changed, so nothing was closed")
                    return
                }
            }
            // Command-W goes to the captured app only, never to whatever is
            // in front. The keystroke (not the close button) keeps the app's
            // own meaning: a tab in a browser, a window elsewhere.
            Self.postCommandPress(keyCode: keyCode, to: target)
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
            if let window = Self.focusedWindow(of: pid, timeout: self.messagingTimeout) {
                self.capturedWindows[sequence] = window
            }
        }
    }

    private static func focusedWindow(of pid: pid_t, timeout: Float) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
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

    private func showHUD(_ message: String, holdSeconds: Double?) {
        hudHide?.cancel()
        hudHide = nil
        DispatchQueue.main.async { [weak self] in self?.hud.show(message: message, holdSeconds: holdSeconds) }
    }

    private func hideHUD() {
        hudHide?.cancel()
        hudHide = nil
        DispatchQueue.main.async { [weak self] in self?.hud.hide() }
    }

    /// A short note when a confirmed action was not carried out.
    private func flashHUD(_ message: String) {
        showHUD(message, holdSeconds: nil)
        let work = DispatchWorkItem { [weak self] in self?.hud.hide() }
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

/// A small panel near the bottom of the screen with the pointer. It never
/// takes focus or clicks.
final class QuitGuardHUD {
    private var panel: NSPanel?
    private let model = QuitGuardHUDModel()

    func show(message: String, holdSeconds: Double?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.message = message
        model.holdSeconds = holdSeconds
        model.startedAt = Date()

        let size = NSSize(width: 360, height: holdSeconds == nil ? 52 : 70)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
