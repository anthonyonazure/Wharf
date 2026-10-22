//
//  WindowBehaviorLogic.swift
//  Wharf
//
//  Pure decisions behind the Window Behavior features: the bundle id lists,
//  the window server scan that finds a green button under the pointer, when
//  an app whose last window closed may be asked to quit, and the Command-Q
//  and Command-W protection state machine. Foundation and CoreGraphics only,
//  so scripts/test-window-behavior.sh can check it without any windows.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later): WindowServerSupport's traffic light scan,
//  WindowMaximizerSupport's exclusion match, and QuitProtectionSupport's
//  shortcut matching and double press timing.
//

import CoreGraphics
import Foundation

// MARK: - Bundle id lists

nonisolated enum WindowBehaviorBundleList {
    /// Trimmed, without blanks or repeats, first spelling kept.
    static func sanitized(_ identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in identifiers {
            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, seen.insert(identifier.lowercased()).inserted else { continue }
            result.append(identifier)
        }
        return result
    }

    /// Bundle ids are case-insensitive on macOS, so the match is too. An app
    /// without a bundle id is never on a list.
    static func contains(_ bundleIdentifier: String?, in list: [String]) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        let wanted = bundleIdentifier.lowercased()
        return list.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
    }
}

// MARK: - Green button

nonisolated enum TrafficLightButton {
    case close
    case zoom
}

nonisolated struct TrafficLightCandidate: Equatable {
    let pid: Int32
    let windowID: UInt32
    let frame: CGRect
}

nonisolated enum TrafficLightHitTest {
    /// The traffic light a click landed on, if any, from the window server's
    /// front to back list. Once a window contains the point the scan is over:
    /// a click on the window in front must never be handed to one behind it.
    /// This runs before any Accessibility query, which some apps answer slowly.
    static func candidate(
        in windows: [[String: Any]],
        at point: CGPoint,
        button: TrafficLightButton,
        ownProcessID: Int32,
        pidIsEligible: (Int32) -> Bool = { _ in true }
    ) -> TrafficLightCandidate? {
        for window in windows {
            guard let bounds = bounds(from: window),
                  bounds.width >= 80,
                  bounds.height >= 80,
                  bounds.contains(point)
            else { continue }

            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ownProcessID,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }

            guard pidIsEligible(ownerPID),
                  contains(point, inTrafficLightAreaOf: bounds, button: button)
            else { return nil }
            return TrafficLightCandidate(pid: ownerPID, windowID: number, frame: bounds)
        }
        return nil
    }

    /// A generous box around where each button sits, measured from the
    /// window's top left corner in window server (top down) coordinates.
    /// Accessibility makes the exact call afterward.
    static func contains(_ point: CGPoint, inTrafficLightAreaOf bounds: CGRect, button: TrafficLightButton) -> Bool {
        let dx = point.x - bounds.minX
        let dy = point.y - bounds.minY
        guard dy >= -6, dy <= 46 else { return false }
        switch button {
        case .close: return dx >= -6 && dx <= 52
        case .zoom: return dx >= 42 && dx <= 104
        }
    }

    static func bounds(from window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}

nonisolated enum GreenButtonAction: Equatable {
    /// Leave the click to the app.
    case passThrough
    /// Fill the usable area, or put the window back when it already does.
    case toggleMaximize
    /// Option held: the real macOS full screen.
    case nativeFullScreen
}

nonisolated enum GreenButtonLogic {
    static func action(command: Bool, control: Bool, option: Bool, shift: Bool) -> GreenButtonAction {
        if command || control || shift { return .passThrough }
        return option ? .nativeFullScreen : .toggleMaximize
    }

    /// A window counts as maximized when every edge is within `tolerance`
    /// of the maximize target; a second click then restores it.
    static func isMaximized(_ current: CGRect, target: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(current.minX - target.minX) <= tolerance
            && abs(current.minY - target.minY) <= tolerance
            && abs(current.width - target.width) <= tolerance
            && abs(current.height - target.height) <= tolerance
    }
}

// MARK: - Quit on close

nonisolated struct QuitOnCloseFacts: Equatable {
    var isListed: Bool
    /// A regular app with a Dock icon. Menu bar apps and agents are never quit.
    var isRegular: Bool
    var isOwnProcess: Bool
    var isTerminated: Bool
    var isHidden: Bool
    /// The app showed at least one window since Wharf started watching it.
    /// An app that launched without windows is left alone.
    var hadWindow: Bool
    /// Standard windows Accessibility still lists, minimized ones included.
    var accessibilityWindowCount: Int
    /// Normal level windows the window server still knows for the app, on
    /// any Space.
    var serverWindowCount: Int
}

nonisolated enum QuitOnCloseLogic {
    /// Every doubt keeps the app running: a wrong "no windows" read would
    /// quit something the user is still using.
    static func shouldQuit(_ facts: QuitOnCloseFacts) -> Bool {
        facts.isListed
            && facts.isRegular
            && !facts.isOwnProcess
            && !facts.isTerminated
            && !facts.isHidden
            && facts.hadWindow
            && facts.accessibilityWindowCount == 0
            && facts.serverWindowCount == 0
    }

    /// Seconds after a close to look again. A closing window stays on screen
    /// while it fades out, so one early look would see it and stop.
    static let checkDelays: [TimeInterval] = [0.35, 0.9, 1.8]

    /// Normal level windows of `pid` in a window server list, ignoring tiny
    /// or transparent ones that are not something a user would call a window.
    static func serverWindowCount(in windows: [[String: Any]], pid: Int32) -> Int {
        windows.filter { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = TrafficLightHitTest.bounds(from: window),
                  bounds.width >= 50, bounds.height >= 50
            else { return false }
            return true
        }.count
    }
}

// MARK: - Quit and close protection

nonisolated enum QuitGuardKey: String, CaseIterable, Equatable {
    case quit
    case close

    var character: String { self == .quit ? "q" : "w" }
    /// The US key position, used only when no character can be read.
    var fallbackKeyCode: Int64 { self == .quit ? 12 : 13 }
    var symbol: String { self == .quit ? "⌘Q" : "⌘W" }

    /// Matches by the typed character first so other layouts work, then by
    /// the US key position.
    static func matching(character: String?, keyCode: Int64) -> QuitGuardKey? {
        if let character = character?.lowercased(), !character.isEmpty {
            return allCases.first { $0.character == character }
        }
        return allCases.first { $0.fallbackKeyCode == keyCode }
    }
}

nonisolated enum QuitGuardMode: String, CaseIterable, Identifiable, Codable {
    case off
    case hold
    case doublePress
    case extraModifier

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "No protection"
        case .hold: "Hold"
        case .doublePress: "Press twice"
        case .extraModifier: "Extra modifier"
        }
    }
}

nonisolated enum QuitGuardModifier: String, CaseIterable, Identifiable, Codable {
    case shift
    case option
    case control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shift: "Shift"
        case .option: "Option"
        case .control: "Control"
        }
    }
    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        }
    }
}

nonisolated struct QuitGuardModifiers: Equatable {
    var command = false
    var shift = false
    var option = false
    var control = false

    var isBareCommand: Bool { command && !shift && !option && !control }

    func isCommand(plusOnly extra: QuitGuardModifier) -> Bool {
        guard command else { return false }
        switch extra {
        case .shift: return shift && !option && !control
        case .option: return option && !shift && !control
        case .control: return control && !shift && !option
        }
    }
}

/// Which mode applies to which app. A per-app override wins over the default;
/// a key the user did not protect is always off.
nonisolated struct QuitGuardPolicy: Equatable {
    var defaultMode: QuitGuardMode
    var overrides: [String: QuitGuardMode]
    var protectsQuit: Bool
    var protectsClose: Bool

    func mode(for bundleIdentifier: String?, key: QuitGuardKey) -> QuitGuardMode {
        switch key {
        case .quit: guard protectsQuit else { return .off }
        case .close: guard protectsClose else { return .off }
        }
        if let bundleIdentifier {
            let wanted = bundleIdentifier.lowercased()
            if let match = overrides.first(where: { $0.key.lowercased() == wanted }) {
                return match.value
            }
        }
        return defaultMode
    }
}

/// The press-by-press decisions for Command-Q and Command-W. The service
/// feeds it key events and timer callbacks and does what it answers; it never
/// touches an event itself, so every path here is checkable without a tap.
nonisolated struct QuitGuardStateMachine {
    enum Decision: Equatable {
        /// Let the event through untouched.
        case pass
        /// Swallow the event; nothing to show or do.
        case swallow
        /// Swallow and show the hold progress HUD.
        case beginHold(QuitGuardKey)
        /// Swallow and show "press again".
        case beginDoublePress(QuitGuardKey)
        /// Swallow and show which modifier to add.
        case showModifierHint(QuitGuardKey, QuitGuardModifier)
        /// Swallow and carry out the shortcut for the app captured at the
        /// first press.
        case confirm(QuitGuardKey, target: Int32)
        /// Swallow (for key events) and hide the HUD.
        case cancel
    }

    struct Pending: Equatable {
        let key: QuitGuardKey
        let mode: QuitGuardMode
        let timestamp: UInt64
        let target: Int32
        let sequence: Int
    }

    static let escapeKeyCode: Int64 = 53
    static let holdRange = 250.0...2_000.0
    static let doublePressRange = 200.0...1_500.0
    static let modifierHintSeconds = 1.5

    var holdMilliseconds = 800.0
    var doublePressMilliseconds = 600.0
    var extraModifier = QuitGuardModifier.shift

    private(set) var pending: Pending?
    /// A confirmed key whose release (and any repeats before it) must not
    /// reach the app, or it would arrive without its press.
    private(set) var swallowing: QuitGuardKey?
    private var nextSequence = 0

    var hasPressInFlight: Bool { pending != nil || swallowing != nil }

    static func clampedHold(_ value: Double) -> Double {
        guard value.isFinite else { return 800 }
        return min(max(value, holdRange.lowerBound), holdRange.upperBound)
    }

    static func clampedDoublePress(_ value: Double) -> Double {
        guard value.isFinite else { return 600 }
        return min(max(value, doublePressRange.lowerBound), doublePressRange.upperBound)
    }

    /// `timestamp` is the event's monotonic nanoseconds. `mode` is the policy
    /// for the frontmost app and `key`, ignored when `key` is nil.
    mutating func keyDown(
        key: QuitGuardKey?,
        keyCode: Int64,
        modifiers: QuitGuardModifiers,
        isRepeat: Bool,
        timestamp: UInt64,
        mode: QuitGuardMode,
        target: Int32
    ) -> Decision {
        if keyCode == Self.escapeKeyCode, pending != nil {
            pending = nil
            return .cancel
        }
        guard modifiers.command || hasPressInFlight else { return .pass }

        if let swallowing, key == swallowing {
            return .swallow
        }
        if let current = pending, current.key != key {
            // Any other key ends the wait and is then judged on its own. The
            // service hides the HUD whenever nothing is pending.
            pending = nil
        }
        guard let key, mode != .off else { return .pass }
        if isRepeat, modifiers.command {
            // Holding the keys down: the first press already decided.
            return pending == nil ? .pass : .swallow
        }

        switch mode {
        case .off:
            return .pass

        case .hold:
            guard modifiers.isBareCommand else { return .pass }
            begin(key, mode: .hold, timestamp: timestamp, target: target)
            return .beginHold(key)

        case .doublePress:
            guard modifiers.isBareCommand else { return .pass }
            if let current = pending, current.mode == .doublePress,
               Self.isWithin(first: current.timestamp, second: timestamp, milliseconds: doublePressMilliseconds) {
                pending = nil
                swallowing = key
                return .confirm(key, target: current.target)
            }
            begin(key, mode: .doublePress, timestamp: timestamp, target: target)
            return .beginDoublePress(key)

        case .extraModifier:
            if modifiers.isCommand(plusOnly: extraModifier) {
                pending = nil
                swallowing = key
                return .confirm(key, target: target)
            }
            guard modifiers.isBareCommand else { return .pass }
            begin(key, mode: .extraModifier, timestamp: timestamp, target: target)
            return .showModifierHint(key, extraModifier)
        }
    }

    mutating func keyUp(key: QuitGuardKey?) -> Decision {
        guard hasPressInFlight, let key else { return .pass }
        if swallowing == key {
            swallowing = nil
            return .swallow
        }
        guard let current = pending, current.key == key else { return .pass }
        switch current.mode {
        case .hold:
            // Let go too early: nothing happens.
            pending = nil
            return .cancel
        case .doublePress, .extraModifier, .off:
            // Still waiting for the second press or the modifier.
            return .swallow
        }
    }

    /// Command released while waiting. The flags event itself always passes.
    mutating func commandChanged(isHeld: Bool) -> Decision {
        // The second press needs Command too, so lifting it is the clearest
        // way to say "never mind" in every mode.
        guard !isHeld, pending != nil else { return .pass }
        pending = nil
        return .cancel
    }

    /// The hold timer for `sequence` fired.
    mutating func holdElapsed(sequence: Int) -> Decision {
        guard let current = pending, current.mode == .hold, current.sequence == sequence else { return .pass }
        pending = nil
        swallowing = current.key
        return .confirm(current.key, target: current.target)
    }

    /// The expiry for `sequence` fired: a double press or modifier hint that
    /// never got its second half.
    mutating func expired(sequence: Int) -> Decision {
        guard let current = pending, current.sequence == sequence, current.mode != .hold else { return .pass }
        pending = nil
        return .cancel
    }

    /// Drops everything, for when the tap stops or the app loses focus.
    mutating func reset() {
        pending = nil
        swallowing = nil
    }

    static func isWithin(first: UInt64, second: UInt64, milliseconds: Double) -> Bool {
        guard second >= first else { return false }
        return second - first <= UInt64(clampedDoublePress(milliseconds) * 1_000_000)
    }

    private mutating func begin(_ key: QuitGuardKey, mode: QuitGuardMode, timestamp: UInt64, target: Int32) {
        nextSequence += 1
        pending = Pending(key: key, mode: mode, timestamp: timestamp, target: target, sequence: nextSequence)
    }
}
