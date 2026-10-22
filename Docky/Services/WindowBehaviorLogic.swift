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
        rightToLeft: Bool = false,
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
                  contains(point, inTrafficLightAreaOf: bounds, button: button, rightToLeft: rightToLeft)
            else { return nil }
            return TrafficLightCandidate(pid: ownerPID, windowID: number, frame: bounds)
        }
        return nil
    }

    /// A generous box around where each button sits, measured from the
    /// window's top leading corner in window server (top down) coordinates.
    /// In a right-to-left layout the buttons sit at the top right, mirrored.
    /// Accessibility makes the exact call afterward.
    static func contains(
        _ point: CGPoint,
        inTrafficLightAreaOf bounds: CGRect,
        button: TrafficLightButton,
        rightToLeft: Bool = false
    ) -> Bool {
        let dx = rightToLeft ? bounds.maxX - point.x : point.x - bounds.minX
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
    /// Every window Accessibility still lists, of any kind (dialogs and
    /// floating panels included), minimized ones too. Nil when the read
    /// failed, which counts as "windows exist".
    var accessibilityWindowCount: Int?
    /// Windows below the menu bar levels the window server still knows for
    /// the app, on any Space. Nil when the read failed.
    var serverWindowCount: Int?
    /// A quit request already went out in this windowless stretch. If the
    /// user cancelled it (in a save prompt, say), asking again would loop.
    var quitAlreadyRequested = false
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
            && !facts.quitAlreadyRequested
            && facts.accessibilityWindowCount == 0
            && facts.serverWindowCount == 0
    }

    /// Seconds after a close to look again. A closing window stays on screen
    /// while it fades out, so one early look would see it and stop.
    static let checkDelays: [TimeInterval] = [0.35, 0.9, 1.8]

    /// Window levels counted as the app's own windows: normal (0), floating
    /// panels (3), modal panels (8) and utility windows, up to but not
    /// including the main menu and status item levels (24 and up).
    static let countedLayers = 0..<20

    /// Windows of `pid` in a window server list, ignoring tiny or
    /// transparent ones that are not something a user would call a window.
    /// Nil in, nil out: an unreadable list is never "no windows".
    static func serverWindowCount(in windows: [[String: Any]]?, pid: Int32) -> Int? {
        guard let windows else { return nil }
        return windows.filter { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  countedLayers.contains(layer),
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = TrafficLightHitTest.bounds(from: window),
                  bounds.width >= 50, bounds.height >= 50
            else { return false }
            return true
        }.count
    }
}

/// One quit request per windowless stretch of an app. The record is set when
/// the request goes out and cleared only once the app shows a standard
/// window again, or quits.
nonisolated struct QuitOnCloseEpisodes: Equatable {
    private(set) var quitSent: Set<Int32> = []

    func hasRequestedQuit(_ pid: Int32) -> Bool { quitSent.contains(pid) }

    mutating func requestedQuit(_ pid: Int32) { quitSent.insert(pid) }

    /// A dialog or panel does not end the stretch; only a standard window does.
    mutating func sawWindow(of pid: Int32, isStandard: Bool) {
        if isStandard { quitSent.remove(pid) }
    }

    mutating func forget(_ pid: Int32) { quitSent.remove(pid) }
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
    /// Remote screens and virtual machines hand Command-Q and Command-W on to
    /// the computer they show. Holding the key back would break that, and a
    /// confirmed quit would end the local session instead. These pass
    /// through unless the user sets a mode for one of them. List adapted
    /// from Vorssaint's QuitProtectionSupport.
    static let passThroughBundleIdentifiers: [String] = [
        // Remote screens
        "com.apple.ScreenSharing",
        "com.apple.RemoteDesktop",
        "com.microsoft.rdc.macos", // Windows App and Microsoft Remote Desktop
        "com.microsoft.rdc.mac",
        "com.p5sys.jump.mac.viewer",
        "com.p5sys.jump.mac.viewer.web",
        "com.citrix.receiver.icaviewer.mac",
        "com.vmware.horizon",
        "com.omnissa.horizon.client.mac",
        "com.edovia.screens.5",
        "com.realvnc.vncviewer",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.carriez.rustdesk",
        "tv.parsec.www",
        // Virtual machines
        "com.parallels.desktop.console",
        "com.parallels.desktop.appstore",
        "com.vmware.fusion",
        "com.utmapp.UTM",
        "org.virtualbox.app.VirtualBoxVM",
        "org.virtualbox.app.VirtualBox",
        "codes.rambo.VirtualBuddy"
    ]

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
            if WindowBehaviorBundleList.contains(bundleIdentifier, in: Self.passThroughBundleIdentifiers) {
                return .off
            }
        }
        return defaultMode
    }
}

/// The press-by-press decisions for Command-Q and Command-W. The service
/// feeds it key events and timer callbacks and does what it answers; it never
/// touches an event itself, so every path here is checkable without a tap.
///
/// Two separate records: `pending` is the protection waiting for its second
/// half, and `ownedKeyCodes` are the physical keys whose press was held
/// back. A held back press owns its key until the key comes up, whatever
/// happens to `pending` in between, so a cancel, an expiry or Escape can
/// never let a repeat or a lone release reach the app.
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
        /// Swallow and carry out the shortcut for the app `target`.
        case confirm(QuitGuardKey, target: Int32)
        /// Swallow (for key events) and hide the HUD.
        case cancel
    }

    struct Pending: Equatable {
        let key: QuitGuardKey
        let keyCode: Int64
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
    /// Physical keys whose press was swallowed and whose release has not
    /// come yet. Their repeats and release are swallowed too.
    private(set) var ownedKeyCodes: Set<Int64> = []
    /// The sequence a confirm finished, so the service can match it with
    /// what it captured at the first press. Nil for a confirm in one press.
    private(set) var confirmedSequence: Int?
    private var nextSequence = 0

    var hasPressInFlight: Bool { pending != nil || !ownedKeyCodes.isEmpty }

    static func clampedHold(_ value: Double) -> Double {
        guard value.isFinite else { return 800 }
        return min(max(value, holdRange.lowerBound), holdRange.upperBound)
    }

    static func clampedDoublePress(_ value: Double) -> Double {
        guard value.isFinite else { return 600 }
        return min(max(value, doublePressRange.lowerBound), doublePressRange.upperBound)
    }

    /// `timestamp` is the event's monotonic nanoseconds. `mode` is the policy
    /// for the frontmost app and `key`, ignored when `key` is nil. `target`
    /// is the frontmost app's process id.
    mutating func keyDown(
        key: QuitGuardKey?,
        keyCode: Int64,
        modifiers: QuitGuardModifiers,
        isRepeat: Bool,
        timestamp: UInt64,
        mode: QuitGuardMode,
        target: Int32
    ) -> Decision {
        if ownedKeyCodes.contains(keyCode) {
            // Still held from a press that was swallowed.
            if isRepeat { return .swallow }
            // A fresh press means the old release was missed; judge it anew.
            ownedKeyCodes.remove(keyCode)
        }
        if keyCode == Self.escapeKeyCode, pending != nil {
            pending = nil
            ownedKeyCodes.insert(keyCode)
            return .cancel
        }
        guard modifiers.command || pending != nil else { return .pass }

        if let current = pending, current.key != key {
            // Any other key ends the wait and is then judged on its own. The
            // service hides the HUD whenever nothing is pending.
            pending = nil
        }
        guard let key, mode != .off, !isRepeat else { return .pass }

        switch mode {
        case .off:
            return .pass

        case .hold:
            guard modifiers.isBareCommand else { return .pass }
            begin(key, keyCode: keyCode, mode: .hold, timestamp: timestamp, target: target)
            return .beginHold(key)

        case .doublePress:
            guard modifiers.isBareCommand else { return .pass }
            if let current = pending, current.mode == .doublePress, current.target == target,
               Self.isWithin(first: current.timestamp, second: timestamp, milliseconds: doublePressMilliseconds) {
                pending = nil
                ownedKeyCodes.insert(keyCode)
                confirmedSequence = current.sequence
                return .confirm(key, target: target)
            }
            // First press, too slow, or a press in another app: start over
            // for the app in front now.
            begin(key, keyCode: keyCode, mode: .doublePress, timestamp: timestamp, target: target)
            return .beginDoublePress(key)

        case .extraModifier:
            if modifiers.isCommand(plusOnly: extraModifier) {
                pending = nil
                ownedKeyCodes.insert(keyCode)
                confirmedSequence = nil
                return .confirm(key, target: target)
            }
            guard modifiers.isBareCommand else { return .pass }
            begin(key, keyCode: keyCode, mode: .extraModifier, timestamp: timestamp, target: target)
            return .showModifierHint(key, extraModifier)
        }
    }

    /// Matched by physical key, never by the character it types now: the
    /// input source can change between press and release.
    mutating func keyUp(keyCode: Int64) -> Decision {
        guard ownedKeyCodes.remove(keyCode) != nil else { return .pass }
        if let current = pending, current.keyCode == keyCode, current.mode == .hold {
            // Let go too early: nothing happens, and the release is swallowed.
            pending = nil
            return .cancel
        }
        // Released after a confirm, a cancel, or while waiting for the second
        // press or the modifier: the press was swallowed, so is the release.
        return .swallow
    }

    /// Command released while waiting. The flags event itself always passes.
    mutating func commandChanged(isHeld: Bool) -> Decision {
        // The second press needs Command too, so lifting it is the clearest
        // way to say "never mind" in every mode.
        guard !isHeld, pending != nil else { return .pass }
        pending = nil
        return .cancel
    }

    /// Another app came to the front. A wait that belongs to a different app
    /// ends; held keys stay owned.
    mutating func frontmostChanged(to pid: Int32) -> Decision {
        guard let current = pending, current.target != pid else { return .pass }
        pending = nil
        return .cancel
    }

    /// The hold timer for `sequence` fired.
    mutating func holdElapsed(sequence: Int) -> Decision {
        guard let current = pending, current.mode == .hold, current.sequence == sequence else { return .pass }
        pending = nil
        confirmedSequence = sequence
        return .confirm(current.key, target: current.target)
    }

    /// The expiry for `sequence` fired: a double press or modifier hint that
    /// never got its second half.
    mutating func expired(sequence: Int) -> Decision {
        guard let current = pending, current.sequence == sequence, current.mode != .hold else { return .pass }
        pending = nil
        return .cancel
    }

    /// Drops everything, for when the tap stops or was disabled and events
    /// may have been missed.
    mutating func reset() {
        pending = nil
        ownedKeyCodes.removeAll()
    }

    static func isWithin(first: UInt64, second: UInt64, milliseconds: Double) -> Bool {
        guard second >= first else { return false }
        return second - first <= UInt64(clampedDoublePress(milliseconds) * 1_000_000)
    }

    private mutating func begin(_ key: QuitGuardKey, keyCode: Int64, mode: QuitGuardMode, timestamp: UInt64, target: Int32) {
        nextSequence += 1
        ownedKeyCodes.insert(keyCode)
        pending = Pending(key: key, keyCode: keyCode, mode: mode, timestamp: timestamp, target: target, sequence: nextSequence)
    }
}

// MARK: - Green button click pairs

/// Keeps a green button click's press and release together. The press is
/// held back while Wharf decides; then either both halves stay with Wharf
/// (the click becomes a maximize) or, when the button is held, the press is
/// handed back late so the app's own hold (the tiling menu) still works and
/// the release follows it. The one combination never allowed is a press
/// that reached the app with its release swallowed.
nonisolated struct GreenButtonPairTracker {
    enum Decision: Equatable {
        case pass
        case swallow
        /// Swallow the release and carry out the click with `token`.
        case perform(token: Int)
        /// Post the held back press now; this pair is the app's from here.
        case replayPress
    }

    /// Seconds a press may stay down before it counts as a hold.
    static let holdSeconds = 0.45

    private(set) var heldPress: Int?
    private var actionValid = false
    private var nextToken = 0

    /// A press Wharf has a trustworthy answer for. Returns the token the
    /// release and the hold timer refer to.
    mutating func pressSwallowed() -> Int {
        nextToken += 1
        heldPress = nextToken
        actionValid = true
        return nextToken
    }

    /// Any other press: whatever was held is over.
    mutating func pressPassed() {
        heldPress = nil
        actionValid = false
    }

    mutating func dragged() -> Decision {
        heldPress == nil ? .pass : .swallow
    }

    mutating func released(insideButton: Bool) -> Decision {
        guard let token = heldPress else { return .pass }
        heldPress = nil
        let valid = actionValid
        actionValid = false
        // Released away from the button cancels, as it does natively.
        return valid && insideButton ? .perform(token: token) : .swallow
    }

    mutating func holdElapsed(token: Int) -> Decision {
        guard heldPress == token else { return .pass }
        heldPress = nil
        actionValid = false
        return .replayPress
    }

    /// The tap was disabled or removed, or the permission went away. Events
    /// may have passed unseen, so the held press is forgotten and the next
    /// release goes through: a stray release is harmless, a swallowed one
    /// after a press the app saw is not.
    mutating func interrupted() {
        heldPress = nil
        actionValid = false
    }
}
