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

    /// True while any menu is open anywhere: the menu bar, a context menu or
    /// a pop-up button. Raising a window then would close the menu.
    static func isMenuOpen(in windows: [HoverWindowInfo]) -> Bool {
        windows.contains { $0.layer == popUpMenuLayer }
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
    var excludedBundleIDs: Set<String> = []
    var frontmostPID: pid_t?
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
        guard let target = input.target else { return .skip(.noWindow) }
        if target.ownerPID == input.ownPID { return .skip(.wharfWindow) }
        if input.targetBundleID == dockBundleID { return .skip(.dock) }
        // Layer 0 is where ordinary app windows live. The Dock, the menu bar,
        // the desktop, banners and floating panels all sit elsewhere.
        if target.layer != 0 { return .skip(.notAnAppWindow) }
        if let bundleID = input.targetBundleID, input.excludedBundleIDs.contains(bundleID) {
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

nonisolated enum SpacesOrderStep: Equatable {
    /// Nothing to change.
    case none
    /// Save `marker`, then turn rearranging off and refresh the Dock.
    case hold(marker: String)
    /// Rearranging is already off: save the "off" marker without touching
    /// the Dock, so turning the feature off later leaves it as it was.
    case remember
    /// Put rearranging back (removing the key when it was missing before),
    /// clear the marker and refresh the Dock.
    case release(removeKey: Bool)
    /// Clear the marker and leave the preference alone.
    case forget
    /// The user turned rearranging back on in System Settings while Wharf
    /// held it off: clear the marker and turn the feature off, so their
    /// choice stands and the switch shows it.
    case letGo
}

nonisolated enum SpacesOrderPlan {
    static let dockDomain = "com.apple.dock"
    static let preferenceKey = "mru-spaces"
    /// Marker values saved in Wharf's defaults: what to put back.
    static let restoreAbsent = "absent"
    static let restoreOn = "on"
    static let restoreOff = "off"

    /// One step toward the wanted state. A saved marker means Wharf holds
    /// rearranging off, whether it turned it off or found it off.
    static func step(wanted: Bool, current: SpacesRearrangeSetting, marker: String?) -> SpacesOrderStep {
        if wanted {
            switch current {
            case .off: return marker == nil ? .remember : .none
            case .unsupported: return .none
            case .absent, .on:
                guard marker == nil else { return .letGo }
                return .hold(marker: current == .absent ? restoreAbsent : restoreOn)
            }
        }
        guard let marker else { return .none }
        // Rearranging was already off when the feature turned on, so whatever
        // it reads now is the user's own.
        guard marker != restoreOff else { return .forget }
        return current == .off ? .release(removeKey: marker == restoreAbsent) : .forget
    }
}

// MARK: - Win key tap

/// Recognizes a lone tap of the Win key, which macOS delivers as Command:
/// pressed and released with no other key, no click and no other modifier in
/// between, and not held so long that it reads as an abandoned shortcut.
nonisolated struct CommandTapDetector {
    static let maximumHoldSeconds: TimeInterval = 0.8

    enum Input {
        /// A modifier changed. `command` is whether Command is now down,
        /// `otherModifiers` whether Shift, Control, Option or Fn is.
        case flagsChanged(command: Bool, otherModifiers: Bool, time: TimeInterval)
        case keyDown
        case mouseDown
    }

    private var commandDown = false
    private var armedAt: TimeInterval?

    /// True exactly when the input completes a lone tap.
    mutating func handle(_ input: Input) -> Bool {
        switch input {
        case .keyDown, .mouseDown:
            armedAt = nil
            return false
        case let .flagsChanged(command, otherModifiers, time):
            defer { commandDown = command }
            if command, !commandDown {
                // Command just went down. Only a press on its own can count.
                armedAt = otherModifiers ? nil : time
                return false
            }
            if command {
                // Still down; another modifier joining spoils the tap.
                if otherModifiers { armedAt = nil }
                return false
            }
            guard commandDown, let armedAt else {
                self.armedAt = nil
                return false
            }
            self.armedAt = nil
            return !otherModifiers && time - armedAt <= Self.maximumHoldSeconds
        }
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
