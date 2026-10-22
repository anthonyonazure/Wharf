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
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): QuitProtectionService's tap, the replay marker, and
//  quitting through a normal terminate request.
//

import AppKit
import Combine
import SwiftUI

final class QuitGuardService {
    static let shared = QuitGuardService()

    /// Set on events this service posts so its own tap lets them through.
    nonisolated static let syntheticMarker: Int64 = 0x5748_5147 // "WHQG"

    private let preferences = WindowBehaviorPreferences.shared
    private var machine = QuitGuardStateMachine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables: Set<AnyCancellable> = []
    private var holdTimer: Timer?
    private var expiry: DispatchWorkItem?
    private var keyCodes: [QuitGuardKey: Int64] = [:]
    private let hud = QuitGuardHUD()

    private init() {}

    func start() {
        observeChanges { [weak self] in
            _ = WindowBehaviorPreferences.shared.quitGuardEnabled
            _ = WindowBehaviorPreferences.shared.quitGuardProtectsQuit
            _ = WindowBehaviorPreferences.shared.quitGuardProtectsClose
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
        let wanted = preferences.quitGuardEnabled
            && (preferences.quitGuardProtectsQuit || preferences.quitGuardProtectsClose)
            && AXIsProcessTrusted()
        if wanted { installTap() } else { removeTap() }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
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
        machine.reset()
        clearTimers()
        hud.hide()
    }

    // MARK: - Event routing

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Keys may have been missed, including the release that ends a swallow.
            machine.reset()
            clearTimers()
            hud.hide()
            if let tap, preferences.quitGuardEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        switch type {
        case .keyDown:
            // Ordinary typing stops here, before any lookup.
            guard flags.contains(.maskCommand) || machine.hasPressInFlight else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let key = QuitGuardKey.matching(
                character: NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
                keyCode: keyCode
            )
            if let key { keyCodes[key] = keyCode }
            let frontmost = NSWorkspace.shared.frontmostApplication
            let mode = key.map { preferences.quitGuardPolicy.mode(for: frontmost?.bundleIdentifier, key: $0) } ?? .off
            machine.holdMilliseconds = preferences.quitGuardHoldMilliseconds
            machine.doublePressMilliseconds = preferences.quitGuardDoublePressMilliseconds
            machine.extraModifier = preferences.quitGuardExtraModifier
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
                target: frontmost?.processIdentifier ?? 0
            )
            return apply(decision, to: event, appName: frontmost?.localizedName)

        case .keyUp:
            guard machine.hasPressInFlight else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let key = QuitGuardKey.matching(
                character: NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
                keyCode: keyCode
            )
            return apply(machine.keyUp(key: key), to: event, appName: nil)

        case .flagsChanged:
            _ = apply(machine.commandChanged(isHeld: flags.contains(.maskCommand)), to: event, appName: nil)
            // Modifier changes always reach the system.
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func apply(
        _ decision: QuitGuardStateMachine.Decision,
        to event: CGEvent,
        appName: String?
    ) -> Unmanaged<CGEvent>? {
        let name = appName ?? "the app"
        switch decision {
        case .pass:
            if machine.pending == nil {
                clearTimers()
                hud.hide()
            }
            return Unmanaged.passUnretained(event)

        case .swallow:
            return nil

        case .beginHold(let key):
            clearTimers()
            let sequence = machine.pending?.sequence ?? 0
            let seconds = machine.holdMilliseconds / 1_000
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.carryOut(self.machine.holdElapsed(sequence: sequence))
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            hud.show(message: "Keep holding \(key.symbol) to \(Self.verb(for: key)) \(name)", holdSeconds: seconds)
            return nil

        case .beginDoublePress(let key):
            scheduleExpiry(after: machine.doublePressMilliseconds / 1_000 + 0.1)
            hud.show(message: "Press \(key.symbol) again to \(Self.verb(for: key)) \(name)", holdSeconds: nil)
            return nil

        case .showModifierHint(let key, let modifier):
            scheduleExpiry(after: QuitGuardStateMachine.modifierHintSeconds)
            hud.show(
                message: "Press \(modifier.symbol)\(key.symbol) to \(Self.verb(for: key)) \(name)",
                holdSeconds: nil
            )
            return nil

        case .confirm, .cancel:
            carryOut(decision)
            return nil
        }
    }

    /// Acts on a timer or key decision: confirm runs the shortcut, cancel
    /// just clears the HUD.
    private func carryOut(_ decision: QuitGuardStateMachine.Decision) {
        switch decision {
        case .confirm(let key, let target):
            clearTimers()
            hud.hide()
            let keyCode = keyCodes[key] ?? key.fallbackKeyCode
            // Out of the tap callback first, so the press is never posted
            // from inside the tap that is still deciding about it.
            DispatchQueue.main.async {
                switch key {
                case .quit:
                    // A normal quit request; the app may still ask to save.
                    if let app = NSRunningApplication(processIdentifier: target), app.terminate() { return }
                    Self.postCommandPress(keyCode: keyCode)
                case .close:
                    Self.postCommandPress(keyCode: keyCode)
                }
            }
        case .cancel:
            clearTimers()
            hud.hide()
        case .pass, .swallow, .beginHold, .beginDoublePress, .showModifierHint:
            break
        }
    }

    private func scheduleExpiry(after seconds: Double) {
        clearTimers()
        let sequence = machine.pending?.sequence ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.carryOut(self.machine.expired(sequence: sequence))
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

    /// Posts a plain Command press of `keyCode`, marked so this tap lets it
    /// through. The extra modifier, if one confirmed it, is left off.
    private static func postCommandPress(keyCode: Int64) {
        for isDown in [true, false] {
            guard let copy = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
            copy.flags = .maskCommand
            copy.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            copy.post(tap: .cghidEventTap)
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
