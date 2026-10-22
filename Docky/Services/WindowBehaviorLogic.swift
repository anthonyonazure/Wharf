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
        guard let front = frontWindow(in: windows, at: point, ownProcessID: ownProcessID),
              pidIsEligible(front.pid),
              contains(point, inTrafficLightAreaOf: front.frame, button: button, rightToLeft: rightToLeft)
        else { return nil }
        return front
    }

    /// The ordinary app window in front at `point`, or nil when anything else
    /// is in front there. Only a fully transparent window is seen through.
    /// Menus, popovers, floating panels, small windows and Wharf's own windows
    /// all end the scan with nil: the click is theirs, never the window's
    /// behind them.
    static func frontWindow(
        in windows: [[String: Any]],
        at point: CGPoint,
        ownProcessID: Int32
    ) -> TrafficLightCandidate? {
        for window in windows {
            guard let bounds = bounds(from: window), bounds.contains(point) else { continue }
            guard (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }

            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  bounds.width >= 80,
                  bounds.height >= 80,
                  let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ownProcessID,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { return nil }
            return TrafficLightCandidate(pid: ownerPID, windowID: number, frame: bounds)
        }
        return nil
    }

    /// Frames of the ordinary app windows in a list, kept between pointer
    /// moves so a click far from every title bar is let by without reading
    /// the window list again.
    static func titleBarWindowFrames(in windows: [[String: Any]], ownProcessID: Int32) -> [CGRect] {
        windows.compactMap { window in
            guard let bounds = bounds(from: window),
                  bounds.width >= 80, bounds.height >= 80,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownProcessID
            else { return nil }
            return bounds
        }
    }

    /// Whether `point` is in the button area of any of `frames`.
    static func mayHit(
        _ point: CGPoint,
        frames: [CGRect],
        button: TrafficLightButton,
        rightToLeft: Bool = false
    ) -> Bool {
        frames.contains { contains(point, inTrafficLightAreaOf: $0, button: button, rightToLeft: rightToLeft) }
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

    /// The window server level of app modal panels (NSModalPanelWindowLevel).
    static let modalPanelLayer = 8

    /// Whether the app has a modal panel on screen. Its other windows then
    /// take no clicks, so the green button is left to the app.
    static func hasModalPanel(in windows: [[String: Any]], pid: Int32) -> Bool {
        windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == modalPanelLayer
                && (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
        }
    }

    /// Where the green button sits after its window moved from `old` to
    /// `new`: the same offset from the window's top leading corner.
    static func shiftedButton(_ button: CGRect, from old: CGRect, to new: CGRect, rightToLeft: Bool = false) -> CGRect {
        let dx = rightToLeft ? new.maxX - old.maxX : new.minX - old.minX
        return button.offsetBy(dx: dx, dy: new.minY - old.minY)
    }
}

/// Throttles the pointer move lookups, keeping the last move of a burst:
/// a move inside the interval schedules one trailing check instead of
/// being dropped, so the lookup still runs where the pointer came to rest.
nonisolated struct GreenButtonMoveThrottle {
    enum Decision: Equatable {
        case runNow
        case runAfter(TimeInterval)
        case alreadyScheduled
    }

    let interval: TimeInterval
    private var lastRun: TimeInterval?
    private var trailingScheduled = false

    init(interval: TimeInterval) { self.interval = interval }

    mutating func moved(at now: TimeInterval) -> Decision {
        if let lastRun, now - lastRun < interval {
            if trailingScheduled { return .alreadyScheduled }
            trailingScheduled = true
            return .runAfter(interval - (now - lastRun))
        }
        lastRun = now
        trailingScheduled = false
        return .runNow
    }

    mutating func trailingRan(at now: TimeInterval) {
        lastRun = now
        trailingScheduled = false
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

/// What a window an app shows after its quit request says about re-arming.
nonisolated enum QuitOnCloseWindowKind: Int, Comparable {
    /// A dialog, sheet, alert, panel, or a modal window of any subrole: the
    /// app's own quit or save prompt looks like this, so it never re-arms.
    case dialog
    /// The subrole or the modal flag could not be read.
    case unknown
    /// Readable, not modal, and not a dialog or panel, but not a standard
    /// window either (some apps draw their own window chrome).
    case ordinary
    /// A standard window that is not modal: a new work window.
    case standard

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    static let dialogSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"
    ]

    /// `isModal` is the window's AXModal value, nil when it cannot be read.
    /// Any doubt is `.unknown` or `.dialog`, neither of which re-arms.
    static func classify(subrole: String?, isModal: Bool?) -> Self {
        if isModal == true { return .dialog }
        guard let subrole, !subrole.isEmpty else { return .unknown }
        if dialogSubroles.contains(subrole) { return .dialog }
        guard isModal == false else { return .unknown }
        return subrole == "AXStandardWindow" ? .standard : .ordinary
    }
}

/// One quit request per windowless stretch of an app. The record is set when
/// the request goes out and cleared only once the app shows a new work
/// window again, or quits.
nonisolated struct QuitOnCloseEpisodes: Equatable {
    private(set) var quitSent: Set<Int32> = []
    /// Apps the user brought to the front after their quit request.
    private(set) var activatedSinceRequest: Set<Int32> = []

    func hasRequestedQuit(_ pid: Int32) -> Bool { quitSent.contains(pid) }

    mutating func requestedQuit(_ pid: Int32) {
        quitSent.insert(pid)
        activatedSinceRequest.remove(pid)
    }

    /// The user brought the app forward. That alone never re-arms: the app
    /// may only be showing its quit or save prompt. It lets an ordinary
    /// (non standard, non dialog) window count as a new work window.
    mutating func activated(_ pid: Int32) {
        if quitSent.contains(pid) { activatedSinceRequest.insert(pid) }
    }

    /// `kind` is the strongest of the app's windows. A standard window ends
    /// the stretch; an ordinary one does after the user activated the app; a
    /// dialog, sheet, modal or unreadable window never does, activated or not.
    mutating func sawWindow(of pid: Int32, kind: QuitOnCloseWindowKind) {
        switch kind {
        case .standard: forget(pid)
        case .ordinary: if activatedSinceRequest.contains(pid) { forget(pid) }
        case .dialog, .unknown: break
        }
    }

    mutating func forget(_ pid: Int32) {
        quitSent.remove(pid)
        activatedSinceRequest.remove(pid)
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

    /// Matches by the typed character first so other Latin layouts (AZERTY,
    /// Dvorak) work, then by the US key position. A layout that types no
    /// ASCII at all (Cyrillic, Greek, Hebrew) gets the key position too,
    /// since macOS itself maps Command shortcuts there by position. ASCII
    /// punctuation is a real, different shortcut (Command-' on Dvorak sits
    /// where Q is on US), so it never falls back.
    static func matching(character: String?, keyCode: Int64) -> QuitGuardKey? {
        if let character = character?.lowercased(), !character.isEmpty,
           character.unicodeScalars.contains(where: \.isASCII) {
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

    /// The modifier that actually confirms `key`. Shift-Command-Q (Log Out)
    /// and Control-Command-Q (Lock Screen) belong to macOS, so Command-Q
    /// confirms with Option instead when either of those is chosen.
    func effective(for key: QuitGuardKey) -> QuitGuardModifier {
        key == .quit && self != .option ? .option : self
    }
}

nonisolated struct QuitGuardModifiers: Equatable {
    var command = false
    var shift = false
    var option = false
    var control = false

    var isBareCommand: Bool { command && !shift && !option && !control }

    /// Shift-Command-Q (Log Out) or Control-Command-Q (Lock Screen), with
    /// nothing else: chords macOS owns, which always pass through.
    var isSystemQuitChord: Bool {
        command && !option && (shift != control)
    }

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
    /// Normalized on the way in, so two spellings of one bundle id can never
    /// leave the answer to dictionary order.
    var overrides: [String: QuitGuardMode] {
        didSet { overrides = Self.normalized(overrides) }
    }
    var protectsQuit: Bool
    var protectsClose: Bool

    init(defaultMode: QuitGuardMode, overrides: [String: QuitGuardMode], protectsQuit: Bool, protectsClose: Bool) {
        self.defaultMode = defaultMode
        self.overrides = Self.normalized(overrides)
        self.protectsQuit = protectsQuit
        self.protectsClose = protectsClose
    }

    /// Trimmed, blank keys dropped, and one entry per bundle id ignoring
    /// case. When two spellings collide, the one first in sorted order wins,
    /// so the result never depends on dictionary order. The surviving key
    /// keeps its spelling for display.
    static func normalized(_ overrides: [String: QuitGuardMode]) -> [String: QuitGuardMode] {
        var seen: Set<String> = []
        var result: [String: QuitGuardMode] = [:]
        for key in overrides.keys.sorted() {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted, let mode = overrides[key] else { continue }
            result[trimmed] = mode
        }
        return result
    }

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
    /// come yet, with the time each was last seen. Their repeats and release
    /// are swallowed too. A key not seen for `ownershipTimeout` stops being
    /// in flight, so a release missed while Secure Input was on cannot leave
    /// the guard busy, but it moves to `quietOwned` rather than being freed.
    private(set) var owned: [Int64: UInt64] = [:]
    /// Owned keys that went quiet past the timeout. Not in flight any more,
    /// yet a repeat of one still refreshes and is swallowed, and its release
    /// is still swallowed: only its key-up or a fresh press ends ownership.
    private(set) var quietOwned: Set<Int64> = []
    var ownedKeyCodes: Set<Int64> { Set(owned.keys) }

    /// The key's press was held back and it has not come up yet, fresh or
    /// quiet. The service routes such a key's repeats and release here even
    /// when nothing is in flight.
    func remembers(keyCode: Int64) -> Bool {
        owned[keyCode] != nil || quietOwned.contains(keyCode)
    }
    /// The tap was disabled and turned back on, so a press may have reached
    /// the app unseen. Until the next key-up or fresh press, a repeat of a
    /// protected shortcut with Command held is swallowed, never passed.
    private(set) var isRecovering = false
    private var recoveringSince: UInt64?
    /// The sequence a confirm finished, so the service can match it with
    /// what it captured at the first press. Nil for a confirm in one press.
    private(set) var confirmedSequence: Int?
    private var nextSequence = 0

    /// Longer than any key repeat delay macOS offers, so a key still held
    /// keeps refreshing itself well inside it.
    static let ownershipTimeout: UInt64 = 10_000_000_000

    var hasPressInFlight: Bool { pending != nil || !owned.isEmpty || isRecovering }

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
        // This key's own ownership is checked before anything is pruned, so
        // a repeat after a long quiet gap is still recognized as held back.
        if remembers(keyCode: keyCode) {
            // Still held from a press that was swallowed.
            if isRepeat {
                quietOwned.remove(keyCode)
                owned[keyCode] = timestamp
                prune(now: timestamp)
                return .swallow
            }
            // A fresh press means the old release was missed; judge it anew.
            owned[keyCode] = nil
            quietOwned.remove(keyCode)
        }
        prune(now: timestamp)
        if isRecovering {
            if isRepeat {
                // The press itself may have been missed while the tap was off.
                if key != nil, mode != .off, modifiers.command {
                    owned[keyCode] = timestamp
                    return .swallow
                }
            } else {
                isRecovering = false
                recoveringSince = nil
            }
        }
        if keyCode == Self.escapeKeyCode, pending != nil {
            pending = nil
            owned[keyCode] = timestamp
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
                owned[keyCode] = timestamp
                confirmedSequence = current.sequence
                return .confirm(key, target: target)
            }
            // First press, too slow, or a press in another app: start over
            // for the app in front now.
            begin(key, keyCode: keyCode, mode: .doublePress, timestamp: timestamp, target: target)
            return .beginDoublePress(key)

        case .extraModifier:
            // Log Out and Lock Screen belong to macOS: never held, never a
            // confirm.
            if key == .quit, modifiers.isSystemQuitChord {
                pending = nil
                return .pass
            }
            let modifier = extraModifier.effective(for: key)
            if modifiers.isCommand(plusOnly: modifier) {
                pending = nil
                owned[keyCode] = timestamp
                confirmedSequence = nil
                return .confirm(key, target: target)
            }
            guard modifiers.isBareCommand else { return .pass }
            begin(key, keyCode: keyCode, mode: .extraModifier, timestamp: timestamp, target: target)
            return .showModifierHint(key, modifier)
        }
    }

    /// Matched by physical key, never by the character it types now: the
    /// input source can change between press and release.
    mutating func keyUp(keyCode: Int64, timestamp: UInt64? = nil) -> Decision {
        let wasOwned = owned.removeValue(forKey: keyCode) != nil
        let wasQuiet = quietOwned.remove(keyCode) != nil
        if let timestamp { prune(now: timestamp) }
        isRecovering = false
        recoveringSince = nil
        guard wasOwned || wasQuiet else { return .pass }
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

    /// The hold timer for `sequence` fired. Time alone never confirms: the
    /// service reads whether the key and Command are physically down right
    /// now, and if either was let go unseen (Secure Input, a disabled tap),
    /// the hold is cancelled.
    mutating func holdElapsed(sequence: Int, keyStillDown: Bool = true, commandStillDown: Bool = true) -> Decision {
        guard let current = pending, current.mode == .hold, current.sequence == sequence else { return .pass }
        pending = nil
        guard keyStillDown, commandStillDown else {
            // A key that is up has no release left to swallow.
            if !keyStillDown {
                owned[current.keyCode] = nil
                quietOwned.remove(current.keyCode)
            }
            return .cancel
        }
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

    /// Drops everything, for when the tap stops and no more events will come.
    mutating func reset() {
        pending = nil
        owned.removeAll()
        quietOwned.removeAll()
        isRecovering = false
        recoveringSince = nil
    }

    /// The tap was disabled and turned back on: events may have been missed.
    /// The wait ends, but the keys already held back stay owned, and a
    /// repeat of a protected shortcut is swallowed until it is clear the key
    /// was let go (see `isRecovering`).
    mutating func interrupted() {
        pending = nil
        isRecovering = true
        recoveringSince = nil
    }

    /// Moves owned keys that have gone quiet for longer than
    /// `ownershipTimeout` out of flight (see `quietOwned`), and ends a
    /// recovery that went quiet as long.
    private mutating func prune(now: UInt64) {
        for (keyCode, seen) in owned where now >= seen && now - seen > Self.ownershipTimeout {
            owned[keyCode] = nil
            quietOwned.insert(keyCode)
        }
        if isRecovering {
            if let since = recoveringSince {
                if now >= since, now - since > Self.ownershipTimeout {
                    isRecovering = false
                    recoveringSince = nil
                }
            } else {
                recoveringSince = now
            }
        }
    }

    static func isWithin(first: UInt64, second: UInt64, milliseconds: Double) -> Bool {
        guard second >= first else { return false }
        return second - first <= UInt64(clampedDoublePress(milliseconds) * 1_000_000)
    }

    private mutating func begin(_ key: QuitGuardKey, keyCode: Int64, mode: QuitGuardMode, timestamp: UInt64, target: Int32) {
        nextSequence += 1
        owned[keyCode] = timestamp
        pending = Pending(key: key, keyCode: keyCode, mode: mode, timestamp: timestamp, target: target, sequence: nextSequence)
    }
}

/// A process as quit protection sees it, for telling whether the app that
/// owns keyboard focus is the app in front or one of its helpers.
nonisolated struct QuitGuardProcess: Equatable {
    var pid: Int32
    var bundleIdentifier: String?
    /// The bundle's folder on disk, nil for a bare executable.
    var bundlePath: String?
    var parentPid: Int32?

    /// True when `self` (the focus owner) is `front` or belongs to it: its
    /// child process, a bundle id under the front app's (com.x.App.helper
    /// under com.x.App), or a bundle inside the front app's bundle (helper
    /// apps in Contents/Frameworks). One way only: the front app is never
    /// counted as part of a panel's family.
    func belongs(to front: QuitGuardProcess) -> Bool {
        if pid == front.pid { return true }
        if let parentPid, parentPid == front.pid { return true }
        if let mine = bundleIdentifier?.lowercased(), let theirs = front.bundleIdentifier?.lowercased(),
           !theirs.isEmpty, mine.hasPrefix(theirs + ".") {
            return true
        }
        if let mine = bundlePath, let theirs = front.bundlePath, !theirs.isEmpty {
            let folder = theirs.hasSuffix("/") ? theirs : theirs + "/"
            if mine.hasPrefix(folder) { return true }
        }
        return false
    }
}

/// The cached answer to "which app owns keyboard focus", read off the tap.
/// Protection steps aside only on a fresh, readable answer naming another
/// app's family; anything stale, unknown or invalidated protects.
nonisolated struct QuitGuardFocusCache: Equatable {
    /// A read older than this is unknown. Keyboard focus can move without
    /// any key event (a click dismissing a panel), so an old answer cannot
    /// be trusted to still hold.
    static let maxAge: UInt64 = 1_500_000_000

    private(set) var owner: QuitGuardProcess?
    private(set) var readAt: UInt64?
    /// Bumped by every invalidation, so a read that started before it is
    /// dropped when it lands.
    private(set) var generation = 0

    /// Focus may have moved: an app switch, a key that can dismiss a panel,
    /// a modifier going down. The answer is unknown until read again.
    mutating func invalidate() {
        owner = nil
        readAt = nil
        generation += 1
    }

    /// Stores a read that started at `generation`. False when the read is
    /// stale (an invalidation came in between) and was dropped.
    @discardableResult
    mutating func store(_ owner: QuitGuardProcess?, readAt: UInt64, startedAt generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.owner = owner
        self.readAt = readAt
        return true
    }

    /// Whether keys should be treated as going somewhere other than `front`
    /// (protection off). Only a fresh read of another family says so.
    func stepsAside(front: QuitGuardProcess?, now: UInt64) -> Bool {
        guard let front, let owner, let readAt, now >= readAt, now - readAt <= Self.maxAge else { return false }
        return !owner.belongs(to: front)
    }
}

/// How often a dead quit protection tap is rebuilt. The count resets only
/// after a rebuilt tap has stayed up for `stableSeconds`, so recoveries
/// spread over a long session never use the tries up, while a tap that
/// dies as soon as it is built still backs off and stops.
nonisolated struct QuitGuardTapRetry: Equatable {
    static let maxRetries = 5
    static let stableSeconds: TimeInterval = 10
    static let quietResetSeconds: TimeInterval = 60

    private(set) var count = 0
    private(set) var lastRetry: TimeInterval?
    private(set) var healthySince: TimeInterval?

    /// The tap is confirmed enabled. Keeps the earliest time, so a settings
    /// change that rechecks a healthy tap does not restart the clock.
    mutating func confirmedEnabled(now: TimeInterval) {
        if healthySince == nil { healthySince = now }
    }

    /// The tap died. Returns the delay before the next rebuild, or nil when
    /// the tries are used up.
    mutating func died(now: TimeInterval) -> TimeInterval? {
        if let healthySince, now - healthySince >= Self.stableSeconds { count = 0 }
        if let lastRetry, now - lastRetry > Self.quietResetSeconds { count = 0 }
        healthySince = nil
        guard count < Self.maxRetries else { return nil }
        count += 1
        lastRetry = now
        return 0.5 * pow(2, Double(count - 1))
    }

    /// Protection was switched off: start over.
    mutating func reset() {
        self = QuitGuardTapRetry()
    }
}

/// What reading an app's focused window gave.
nonisolated enum QuitGuardWindowRead: Equatable {
    /// A window was read.
    case window
    /// The app answered: it has no focused window.
    case noFocusedWindow
    /// The app cannot be asked at all (no Accessibility support, or no answer).
    case unreadable
}

/// Whether a confirmed Command-W may be sent, judged from the focused window
/// read at the first press and again right before sending.
nonisolated enum QuitGuardCloseCheck {
    enum Verdict: Equatable {
        case post
        /// The app says no window is in front: nothing to close.
        case noWindow
        /// A different window is in front now, or it can no longer be read.
        case windowChanged
    }

    /// `captured` is nil for a one-press confirm (nothing was captured), and
    /// `.unreadable` when the capture never answered. `sameWindow` says the
    /// two reads are the same window, when both are `.window`.
    static func verdict(captured: QuitGuardWindowRead?, current: QuitGuardWindowRead, sameWindow: Bool) -> Verdict {
        switch current {
        case .noFocusedWindow:
            return .noWindow
        case .unreadable:
            // An app that cannot be read at all still gets its Command-W, as
            // without Wharf. One that showed a window before and no longer
            // answers might have a different window in front: nothing.
            return captured == nil || captured == .unreadable ? .post : .windowChanged
        case .window:
            switch captured {
            case nil: return .post
            case .window: return sameWindow ? .post : .windowChanged
            case .noFocusedWindow, .unreadable: return .windowChanged
            }
        }
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
