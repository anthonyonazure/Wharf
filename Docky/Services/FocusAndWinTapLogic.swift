//
//  FocusAndWinTapLogic.swift
//  Wharf
//
//  The decisions behind three Behavior features, kept apart from AppKit so
//  every case can be checked without real windows, a real Dock or a real
//  keyboard (see scripts/test-focus-and-wintap.sh):
//
//  - Focus follows mouse: the hover dwell timer and the "should this window
//    be raised" gate.
//  - Fixed Space order: what to write to the Dock's mru-spaces preference,
//    and what to put back.
//  - Win key tap: a lone press and release of Command, with nothing between.
//
//  The dwell state and the Spaces order steps are adapted from Vorssaint
//  (vorssaint/vorssaint-utils, GPL-3.0): FocusFollowsMouseSupport.swift and
//  SpacesOrderHold.swift.
//
//  Foundation and CoreGraphics only. Every type is nonisolated: the Win key
//  detector runs on the keyboard tap thread, not the main actor.
//

import CoreGraphics
import Foundation

// MARK: - Focus follows mouse: timing

nonisolated enum FocusFollowsMouseTiming {
    static let defaultDelayMilliseconds = 300
    static let delayRange = 100...2_000

    static func clampedDelay(_ milliseconds: Int) -> Int {
        min(max(milliseconds, delayRange.lowerBound), delayRange.upperBound)
    }

    /// The delay to use for a stored value, and whether the store should be
    /// rewritten so an out of range or malformed value does not come back on
    /// the next launch.
    static func storedDelay(_ raw: Any?) -> (value: Int, needsRewrite: Bool) {
        guard let raw else { return (defaultDelayMilliseconds, false) }
        guard let number = raw as? Int else { return (defaultDelayMilliseconds, true) }
        let clamped = clampedDelay(number)
        return (clamped, clamped != number)
    }
}

// MARK: - App exclusion lists

/// Bundle identifiers are case insensitive, so every exclusion list compares
/// them lowercased. The list itself keeps the spelling it was added with, for
/// display.
nonisolated enum BundleIDList {
    static func normalized(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The set to match against at run time.
    static func matchSet(_ bundleIDs: [String]) -> Set<String> {
        Set(bundleIDs.map(normalized).filter { !$0.isEmpty })
    }

    static func contains(_ bundleIDs: [String], _ bundleID: String) -> Bool {
        let key = normalized(bundleID)
        return bundleIDs.contains { normalized($0) == key }
    }

    /// `bundleIDs` with `bundleID` appended, trimmed, unless it is empty or
    /// already there in any case.
    static func adding(_ bundleID: String, to bundleIDs: [String]) -> [String] {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contains(bundleIDs, trimmed) else { return bundleIDs }
        return bundleIDs + [trimmed]
    }

    /// Drops later entries that differ from an earlier one only in case.
    static func deduplicated(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        return bundleIDs.filter { seen.insert(normalized($0)).inserted && !normalized($0).isEmpty }
    }

    /// `bundleIDs` without `bundleID` in any case or spacing.
    static func removing(_ bundleID: String, from bundleIDs: [String]) -> [String] {
        let key = normalized(bundleID)
        return bundleIDs.filter { normalized($0) != key }
    }

    /// Why a typed bundle ID is refused, or nil when it is acceptable. A
    /// bundle ID is reverse DNS: two or more parts separated by dots, each
    /// made of letters, digits and hyphens. Underscores are refused, as
    /// Apple's rules for the key refuse them.
    ///
    /// `allowsExecutableName` is for a list whose service also matches an
    /// app without a bundle ID by its executable's name (`matchKey`): there
    /// a name without dots is taken as that program name, so `alacritty` or
    /// `xterm` can be added. It may hold letters, digits, spaces, hyphens and
    /// underscores, never a slash or a colon. Other lists refuse it, since
    /// such an entry would never match there.
    static func validationError(_ typed: String, allowsExecutableName: Bool = false) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return allowsExecutableName ? "Type a bundle ID or a program name." : "Type a bundle ID." }
        if allowsExecutableName, !trimmed.contains(".") {
            let program = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
            if trimmed.unicodeScalars.contains(where: { !program.contains($0) }) {
                return "A program name uses only letters, digits, spaces, hyphens and underscores."
            }
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "A bundle ID uses only letters, digits, dots and hyphens."
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count < 2 { return "A bundle ID has at least two parts separated by a dot, like com.example.App." }
        if parts.contains(where: \.isEmpty) { return "A bundle ID cannot start or end with a dot or have two dots in a row." }
        return nil
    }

    /// The key an app is matched by: its bundle ID, or for the rare app
    /// without one, its executable's file name. Lowercased like the list.
    static func matchKey(bundleID: String?, executableName: String?) -> String? {
        if let bundleID, !normalized(bundleID).isEmpty { return normalized(bundleID) }
        if let executableName, !normalized(executableName).isEmpty { return normalized(executableName) }
        return nil
    }
}

nonisolated struct HoverDwellEvaluation: Equatable {
    let point: CGPoint
    let generation: UInt64
}

/// Waits for the pointer to rest before anything is raised, so windows the
/// pointer crosses on its way somewhere else are not reshuffled. Any movement
/// restarts the wait. Once an attempt finishes, nothing happens again until
/// the pointer moves.
nonisolated struct HoverDwellState: Equatable {
    private enum Phase: Equatable {
        case pending, evaluating, finished
    }

    private(set) var point: CGPoint?
    private(set) var movedAt: TimeInterval = 0
    private(set) var generation: UInt64 = 0
    private var phase = Phase.pending

    var hasPendingEvaluation: Bool {
        point != nil && phase == .pending
    }

    mutating func recordMovement(to point: CGPoint, at time: TimeInterval) {
        self.point = point
        movedAt = time
        generation &+= 1
        phase = .pending
    }

    /// Forget the pointer, for a Space switch, a wake or a display change.
    mutating func reset() {
        point = nil
        generation &+= 1
        phase = .pending
    }

    /// An evaluation once the pointer has rested for the delay, otherwise nil.
    mutating func nextEvaluation(at time: TimeInterval, delayMilliseconds: Int) -> HoverDwellEvaluation? {
        guard let point,
              hasPendingEvaluation,
              time - movedAt >= Double(FocusFollowsMouseTiming.clampedDelay(delayMilliseconds)) / 1_000
        else { return nil }
        phase = .evaluating
        return HoverDwellEvaluation(point: point, generation: generation)
    }

    mutating func finishEvaluation(_ evaluation: HoverDwellEvaluation) {
        guard isCurrent(evaluation) else { return }
        phase = .finished
    }

    /// False once the pointer has moved since the evaluation began.
    func isCurrent(_ evaluation: HoverDwellEvaluation) -> Bool {
        evaluation.generation == generation && phase == .evaluating
    }
}

// MARK: - Focus follows mouse: which window

/// The parts of one window server entry the gate needs.
nonisolated struct HoverWindowInfo: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect
}

nonisolated enum HoverWindowScan {
    /// Menus, pop-up lists and context menus all sit at this level while open.
    static let popUpMenuLayer = 101
    /// The pointer itself is a small window server window at this level,
    /// always on top of whatever it points at.
    static let cursorLayer = 2_147_483_630

    /// One `CGWindowListCopyWindowInfo` entry, or nil when it lacks the
    /// fields the gate needs or is fully transparent.
    static func info(from entry: [String: Any]) -> HoverWindowInfo? {
        guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { return nil }
        return HoverWindowInfo(windowID: number, ownerPID: pid, layer: layer, bounds: bounds)
    }

    /// The window under the pointer. `pointerWindowID` is AppKit's answer to
    /// "which window would take a click here", which already skips overlays
    /// that let clicks through. Without it, the frontmost window containing
    /// the point is used. `windows` is front to back, as the window server
    /// lists them.
    static func target(in windows: [HoverWindowInfo], at point: CGPoint,
                       pointerWindowID: CGWindowID?) -> HoverWindowInfo? {
        if let pointerWindowID, pointerWindowID != 0 {
            return windows.first { $0.windowID == pointerWindowID && $0.bounds.contains(point) }
        }
        return windows.first { $0.layer < cursorLayer && $0.bounds.contains(point) }
    }

    /// True while another app shows a menu: the menu bar, a context menu, a
    /// pop-up button or a menu bar extra. Raising a window then would close
    /// the menu. A window at the menu level counts only when its owner is one
    /// that shows menus (`menuOwnerPIDs`: the frontmost app and background
    /// or accessory apps such as menu bar extras), never Wharf itself
    /// (`ownPID`): Wharf's own menus are known from its menu tracking
    /// instead, so its panels cannot block hover focus. Nil `menuOwnerPIDs`
    /// accepts any owner.
    static func isMenuOpen(in windows: [HoverWindowInfo], ownPID: pid_t = 0,
                           menuOwnerPIDs: Set<pid_t>? = nil) -> Bool {
        windows.contains { window in
            window.layer == popUpMenuLayer
                && window.ownerPID != ownPID
                && (menuOwnerPIDs?.contains(window.ownerPID) ?? true)
        }
    }

    /// True when the frontmost app shows an ordinary window that covers a
    /// whole display, the way a full-screen app or game does. `displayBounds`
    /// are in the same top-left global coordinates as the window list.
    static func isFullScreen(pid: pid_t?, in windows: [HoverWindowInfo], displayBounds: [CGRect]) -> Bool {
        guard let pid else { return false }
        return windows.contains { window in
            window.ownerPID == pid && window.layer == 0
                && displayBounds.contains { $0.integral == window.bounds.integral }
        }
    }
}

nonisolated enum HoverSkipReason: Equatable {
    case menuOpen
    case buttonOrModifierHeld
    case displayNotEnabled
    case noWindow
    case notAnAppWindow
    case wharfWindow
    case dock
    case excludedApp
    case alreadyFocused
    /// The app in front is on the excluded list: hovering never takes focus
    /// away from it.
    case frontmostExcluded
    /// The app in front is full screen (often a game holding the pointer).
    case frontmostFullScreen
}

nonisolated enum HoverFocusDecision: Equatable {
    case raise(windowID: CGWindowID, pid: pid_t)
    case skip(HoverSkipReason)
}

nonisolated struct HoverFocusInput {
    var menuOpen = false
    var mouseButtonsDown = false
    var modifiersHeld = false
    var displayEnabled = true
    var target: HoverWindowInfo?
    var targetBundleID: String?
    var ownPID: pid_t = 0
    /// Normalized with `BundleIDList.matchSet`.
    var excludedBundleIDs: Set<String> = []
    var frontmostPID: pid_t?
    var frontmostBundleID: String?
    var frontmostIsFullScreen = false
    /// The focused window of the frontmost app, when Accessibility answers.
    var focusedWindowID: CGWindowID?
}

nonisolated enum HoverFocusGate {
    static let dockBundleID = "com.apple.dock"

    /// Whether the window under a resting pointer should be raised. Ordered
    /// so the cheapest and most important refusals come first: never steal
    /// focus mid-menu, mid-drag or mid-shortcut.
    static func decide(_ input: HoverFocusInput) -> HoverFocusDecision {
        if input.menuOpen { return .skip(.menuOpen) }
        if input.mouseButtonsDown || input.modifiersHeld { return .skip(.buttonOrModifierHeld) }
        if !input.displayEnabled { return .skip(.displayNotEnabled) }
        if let front = input.frontmostBundleID.map(BundleIDList.normalized),
           input.excludedBundleIDs.contains(front) {
            return .skip(.frontmostExcluded)
        }
        if input.frontmostIsFullScreen { return .skip(.frontmostFullScreen) }
        guard let target = input.target else { return .skip(.noWindow) }
        if target.ownerPID == input.ownPID { return .skip(.wharfWindow) }
        let bundleID = input.targetBundleID.map(BundleIDList.normalized)
        if bundleID == dockBundleID { return .skip(.dock) }
        // Layer 0 is where ordinary app windows live. The Dock, the menu bar,
        // the desktop, banners and floating panels all sit elsewhere.
        if target.layer != 0 { return .skip(.notAnAppWindow) }
        if let bundleID, input.excludedBundleIDs.contains(bundleID) {
            return .skip(.excludedApp)
        }
        if input.frontmostPID == target.ownerPID {
            // Same app in front. Without a known focused window, leave it:
            // asking again can release a game's captured pointer.
            guard let focused = input.focusedWindowID, focused != target.windowID else {
                return .skip(.alreadyFocused)
            }
        }
        return .raise(windowID: target.windowID, pid: target.ownerPID)
    }
}

/// The last look before a raise. Finding the window takes Accessibility
/// calls off the main thread, and the world can change meanwhile: the pointer
/// moves (even onto one of Wharf's own windows, which the global monitor
/// does not see), a menu opens, a click or shortcut starts, or the feature is
/// switched off. Everything is read fresh, right before raising.
nonisolated struct HoverCommitCheck {
    /// How far the live pointer may sit from where it rested, in points.
    static let pointerTolerance: CGFloat = 3

    var featureActive = true
    var evaluationCurrent = true
    var livePointer: CGPoint?
    var receivingWindowID: CGWindowID?
    var menuOpen = false
    var buttonOrModifierHeld = false

    func allowsRaise(of windowID: CGWindowID, restingAt point: CGPoint) -> Bool {
        guard featureActive, evaluationCurrent, !menuOpen, !buttonOrModifierHeld,
              let livePointer,
              abs(livePointer.x - point.x) <= Self.pointerTolerance,
              abs(livePointer.y - point.y) <= Self.pointerTolerance
        else { return false }
        // AppKit's answer must name the same window. Unknown means unsure,
        // and unsure means no raise.
        return receivingWindowID == windowID
    }
}

// MARK: - Fixed Space order

/// How the Dock arranges Spaces, as its `mru-spaces` preference reads. A
/// missing key is the system default, which rearranges by most recent use.
nonisolated enum SpacesRearrangeSetting: Equatable {
    case absent, on, off
    /// Forced by a management profile or stored as something other than a
    /// Boolean. Wharf never writes over it.
    case unsupported

    static func from(raw: Any?, isForced: Bool) -> SpacesRearrangeSetting {
        if isForced { return .unsupported }
        guard let raw else { return .absent }
        guard let number = raw as? NSNumber else { return .unsupported }
        return number.boolValue ? .on : .off
    }
}

/// How far a change to the Dock preference got. Saved, and flushed to disk,
/// before the Dock preference is touched, so a crash at any point leaves
/// enough behind to finish or undo the change on the next launch.
nonisolated enum SpacesHoldPhase: String, Equatable {
    /// About to turn rearranging off; the Dock may or may not have it yet.
    case pendingHold
    /// Rearranging is off and Wharf holds it.
    case held
    /// About to put the old value back; the Dock may or may not have it yet.
    case pendingRelease
}

/// Wharf's recovery record for fixed Space order: what `mru-spaces` read
/// before Wharf changed it, and how far the change got. Present only while
/// Wharf holds the setting or is in the middle of changing it.
nonisolated struct SpacesOrderJournal: Equatable {
    /// One of the `SpacesOrderPlan.restore...` values.
    var restore: String
    var phase: SpacesHoldPhase
}

nonisolated enum SpacesOrderStep: Equatable {
    /// Nothing to change.
    case none
    /// Save a pending journal with `restore`, then turn rearranging off,
    /// mark the journal held and refresh the Dock.
    case hold(restore: String)
    /// The Dock already reads off after an interrupted hold: mark it held.
    case confirmHold
    /// Rearranging is already off: save a held "off" journal without
    /// touching the Dock, so turning the feature off later leaves it as it was.
    case remember
    /// Mark the journal pending release, put rearranging back (removing the
    /// key when it was missing before), and clear the journal only once the
    /// Dock reads the old value.
    case release(removeKey: Bool)
    /// Clear the journal and leave the preference alone.
    case forget
    /// The user turned rearranging back on in System Settings while Wharf
    /// held it off: clear the journal and turn the feature off, so their
    /// choice stands and the switch shows it.
    case letGo
}

nonisolated enum SpacesOrderPlan {
    static let dockDomain = "com.apple.dock"
    static let preferenceKey = "mru-spaces"
    /// Values for `SpacesOrderJournal.restore`: what to put back.
    static let restoreAbsent = "absent"
    static let restoreOn = "on"
    static let restoreOff = "off"

    /// One step toward the wanted state. Only a held journal with rearranging
    /// back on means the user changed it; a pending one means Wharf was cut
    /// off mid change and should finish or undo it.
    static func step(wanted: Bool, current: SpacesRearrangeSetting, journal: SpacesOrderJournal?) -> SpacesOrderStep {
        if current == .unsupported {
            // Managed now: never write, and drop any record of an old change.
            return journal == nil ? .none : .forget
        }
        if wanted {
            guard let journal else {
                if current == .off { return .remember }
                return .hold(restore: current == .absent ? restoreAbsent : restoreOn)
            }
            switch journal.phase {
            case .held:
                return current == .off ? .none : .letGo
            case .pendingHold:
                // The Dock write may not have happened: retry it with the
                // value saved before, which is still what to put back.
                return current == .off ? .confirmHold : .hold(restore: journal.restore)
            case .pendingRelease:
                // Turned back on while a release was unfinished.
                if current == .off { return .confirmHold }
                return .hold(restore: current == .absent ? restoreAbsent : restoreOn)
            }
        }
        guard let journal else { return .none }
        // Rearranging was already off when the feature turned on, so whatever
        // it reads now is the user's own.
        guard journal.restore != restoreOff else { return .forget }
        // Still off: Wharf's write is in place (or might be), so put the old
        // value back. Anything else is either the restored value or the
        // user's own choice; leave it.
        return current == .off ? .release(removeKey: journal.restore == restoreAbsent) : .forget
    }
}

// MARK: - Win key tap

/// Recognizes a lone tap of the Win key, which macOS delivers as Command:
/// pressed and released with no other key, no click, no scroll, no mouse
/// button held and no other modifier in between, and not held so long that
/// it reads as an abandoned shortcut.
nonisolated struct CommandTapDetector {
    static let maximumHoldSeconds: TimeInterval = 0.8
    /// A key the hardware saw this long before Command went down still
    /// cancels the tap. Errs toward doing nothing.
    static let otherKeySlackSeconds: TimeInterval = 0.05

    enum Input {
        /// A modifier changed. `command` is whether Command is now down,
        /// `otherModifiers` whether Shift, Control, Option or Fn is, and
        /// `mouseHeld` whether any mouse button is down right now (Command
        /// during a drag changes the drag, it is not a tap).
        /// `lastOtherKeyAt` is when the hardware last saw a key or media key
        /// go down, on the same clock as `time`. It catches keys the tap
        /// never receives, such as Command+Tab and Command+Space, which the
        /// window server can consume before the session tap.
        /// `otherKeyHeld` is whether the hardware reports any key other than
        /// Command physically down right now (see `CommandTapKeys`): a key
        /// held from before the press, or one that does not repeat, is not
        /// caught by `lastOtherKeyAt`.
        /// `capsLock` is the Caps Lock light. It is a latched state, so being
        /// on proves nothing; only a change during the press cancels.
        case flagsChanged(command: Bool, otherModifiers: Bool, time: TimeInterval,
                          mouseHeld: Bool = false, lastOtherKeyAt: TimeInterval? = nil,
                          otherKeyHeld: Bool = false, capsLock: Bool = false)
        case keyDown
        /// Volume, brightness and media keys (event type 14).
        case systemDefined
        case mouseDown
        /// Command with the scroll wheel zooms in many apps.
        case scrollWheel
    }

    private var commandDown = false
    private var armedAt: TimeInterval?
    private var armedCapsLock = false

    /// True while a press or a pending tap is remembered.
    var isIdle: Bool { !commandDown && armedAt == nil }

    /// Forget everything, for a tap that was re-armed or reinstalled and may
    /// have missed events in between. A release that follows does not fire.
    mutating func reset() {
        commandDown = false
        armedAt = nil
    }

    /// Whether the last input was a release that only the hardware key check
    /// stopped, for the status file. If that check ever counted Command
    /// itself, every tap would end here.
    private(set) var lastCancelledByHardwareKey = false

    /// True exactly when the input completes a lone tap.
    mutating func handle(_ input: Input) -> Bool {
        lastCancelledByHardwareKey = false
        switch input {
        case .keyDown, .systemDefined, .mouseDown, .scrollWheel:
            armedAt = nil
            return false
        case let .flagsChanged(command, otherModifiers, time, mouseHeld, lastOtherKeyAt, otherKeyHeld, capsLock):
            defer { commandDown = command }
            if command, !commandDown {
                // Command just went down. Only a press on its own can count:
                // no other modifier, no button and no other key held.
                armedAt = otherModifiers || mouseHeld || otherKeyHeld ? nil : time
                armedCapsLock = capsLock
                return false
            }
            if command {
                // Still down; another modifier joining, or Caps Lock
                // switching, spoils the tap.
                if otherModifiers || mouseHeld || otherKeyHeld || capsLock != armedCapsLock { armedAt = nil }
                return false
            }
            guard commandDown, let armedAt else {
                self.armedAt = nil
                return false
            }
            self.armedAt = nil
            if capsLock != armedCapsLock { return false }
            if otherKeyHeld {
                lastCancelledByHardwareKey = true
                return false
            }
            if let lastOtherKeyAt, lastOtherKeyAt >= armedAt - Self.otherKeySlackSeconds {
                lastCancelledByHardwareKey = true
                return false
            }
            let held = time - armedAt
            return !otherModifiers && !mouseHeld && held >= 0 && held <= Self.maximumHoldSeconds
        }
    }
}

/// Which physically held keys stop a Win key tap. Virtual key codes from
/// Carbon's Events.h, repeated here so this file stays Foundation only.
nonisolated enum CommandTapKeys {
    enum Kind: Equatable {
        /// Left or right Command: the Win key itself.
        case command
        /// Shift, Option, Control or Fn, either side.
        case otherModifier
        /// Caps Lock. The hardware may report its light rather than the key,
        /// so being down is not trusted; the detector watches for a change
        /// of the light instead.
        case capsLock
        case key
    }

    static let rightCommand: UInt16 = 0x36
    static let command: UInt16 = 0x37
    static let capsLockKey: UInt16 = 0x39
    static let otherModifiers: Set<UInt16> = [0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
    /// Every key code a keyboard reports.
    static let scanned: ClosedRange<UInt16> = 0...0x7F

    static func kind(of keyCode: UInt16) -> Kind {
        if keyCode == command || keyCode == rightCommand { return .command }
        if keyCode == capsLockKey { return .capsLock }
        if otherModifiers.contains(keyCode) { return .otherModifier }
        return .key
    }

    /// True when any held key other than Command and Caps Lock should stop
    /// the tap. `isDown` asks the hardware about one key code.
    static func otherKeyHeld(isDown: (UInt16) -> Bool) -> Bool {
        scanned.contains { code in
            switch kind(of: code) {
            case .command, .capsLock: false
            case .otherModifier, .key: isDown(code)
            }
        }
    }
}

/// Which events the Windows keyboard tap listens to, and how to read their
/// clocks. Pure, so the choices can be checked without a real tap.
nonisolated enum WinTapEvents {
    /// `NX_SYSDEFINED`: volume, brightness and media keys. CoreGraphics has
    /// no named case for it.
    static let systemDefinedType: UInt32 = 14

    /// Whether Win+Shift+S takes a snip. Excluded apps (remote desktops,
    /// virtual machines, terminals) keep the Win key, so the chord reaches
    /// them untouched unless the user asked for snips there too.
    static func snipAllowed(enabled: Bool, frontmostExcluded: Bool, inExcludedApps: Bool) -> Bool {
        enabled && (!frontmostExcluded || inExcludedApps)
    }

    /// Key events always, for the Control translation and the snip. The rest
    /// only while a Win key tap can open something; with the action set to
    /// Nothing, clicks, scrolls and modifier changes never reach the tap.
    static func mask(for action: WinKeyTapAction) -> CGEventMask {
        var mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard action != .off else { return mask }
        mask |= (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventMask(systemDefinedType))
        return mask
    }

    /// When an event happened, in seconds on the `systemUptime` clock.
    ///
    /// `CGEvent.timestamp` is documented as nanoseconds since startup, but on
    /// Apple silicon it is widely reported to carry mach ticks; on Intel the
    /// two agree. Both readings are tried, mach ticks first, and one is
    /// trusted only when it lands within `plausibleAgeSeconds` before `now`.
    ///
    /// Nil when neither reading is plausible: an event delivered that late
    /// (or with a stamp from the future) cannot have its hold measured, and
    /// pretending it happened now would turn a long hold into a short one.
    /// The caller then forgets the press, so nothing opens. A missing stamp
    /// (zero) is the one case read as `now`: it says nothing about delay,
    /// and refusing it would switch the Win key tap off for good on a system
    /// that never stamps events.
    static let plausibleAgeSeconds: TimeInterval = 1

    static func eventTime(timestamp: UInt64, timebaseNumer: UInt32, timebaseDenom: UInt32,
                          now: TimeInterval) -> TimeInterval? {
        guard timestamp != 0 else { return now }
        var candidates: [Double] = []
        if timebaseDenom != 0 {
            candidates.append(Double(timestamp) * Double(timebaseNumer) / Double(timebaseDenom) / 1_000_000_000)
        }
        candidates.append(Double(timestamp) / 1_000_000_000)
        for seconds in candidates {
            let age = now - seconds
            if age >= -0.01, age <= plausibleAgeSeconds { return min(seconds, now) }
        }
        return nil
    }
}

/// What a Win key tap opens.
nonisolated enum WinKeyTapAction: String, CaseIterable, Identifiable {
    case off
    case startMenu
    case launchpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Nothing"
        case .startMenu: "Start Menu"
        case .launchpad: "Launchpad"
        }
    }
}
