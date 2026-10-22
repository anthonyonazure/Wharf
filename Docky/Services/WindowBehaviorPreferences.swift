//
//  WindowBehaviorPreferences.swift
//  Wharf
//
//  Settings for the Window Behavior pane: green button maximize, quit on
//  close, and Command-Q and Command-W protection. Kept apart from
//  DockyPreferences so the feature stays in its own files; it uses the same
//  Keys and DefaultValues layout and the same UserDefaults domain, under the
//  `wharf.windowBehavior.` prefix.
//

import Foundation
import Observation

@Observable
final class WindowBehaviorPreferences {
    static let shared = WindowBehaviorPreferences()

    // MARK: Green button maximize

    /// The green button fills the usable area instead of entering full screen.
    var maximizeEnabled: Bool {
        didSet { store(maximizeEnabled, oldValue, Keys.maximizeEnabled) }
    }

    /// Bundle ids whose green button keeps the macOS behavior.
    var maximizeExceptions: [String] {
        didSet { storeList(maximizeExceptions, oldValue, Keys.maximizeExceptions) }
    }

    // MARK: Quit on close

    var quitOnCloseEnabled: Bool {
        didSet { store(quitOnCloseEnabled, oldValue, Keys.quitOnCloseEnabled) }
    }

    /// Bundle ids that quit when their last window closes.
    var quitOnCloseApps: [String] {
        didSet { storeList(quitOnCloseApps, oldValue, Keys.quitOnCloseApps) }
    }

    // MARK: Quit and close protection

    var quitGuardEnabled: Bool {
        didSet { store(quitGuardEnabled, oldValue, Keys.quitGuardEnabled) }
    }

    var quitGuardProtectsQuit: Bool {
        didSet { store(quitGuardProtectsQuit, oldValue, Keys.quitGuardProtectsQuit) }
    }

    var quitGuardProtectsClose: Bool {
        didSet { store(quitGuardProtectsClose, oldValue, Keys.quitGuardProtectsClose) }
    }

    var quitGuardDefaultMode: QuitGuardMode {
        didSet {
            guard quitGuardDefaultMode != oldValue else { return }
            defaults.set(quitGuardDefaultMode.rawValue, forKey: Keys.quitGuardDefaultMode)
        }
    }

    /// Per-app modes that replace the default, keyed by bundle id.
    var quitGuardOverrides: [String: QuitGuardMode] {
        didSet {
            guard quitGuardOverrides != oldValue else { return }
            defaults.set(quitGuardOverrides.mapValues(\.rawValue), forKey: Keys.quitGuardOverrides)
        }
    }

    var quitGuardHoldMilliseconds: Double {
        didSet {
            let clamped = QuitGuardStateMachine.clampedHold(quitGuardHoldMilliseconds)
            if clamped != quitGuardHoldMilliseconds {
                quitGuardHoldMilliseconds = clamped
                return
            }
            store(quitGuardHoldMilliseconds, oldValue, Keys.quitGuardHoldMilliseconds)
        }
    }

    var quitGuardDoublePressMilliseconds: Double {
        didSet {
            let clamped = QuitGuardStateMachine.clampedDoublePress(quitGuardDoublePressMilliseconds)
            if clamped != quitGuardDoublePressMilliseconds {
                quitGuardDoublePressMilliseconds = clamped
                return
            }
            store(quitGuardDoublePressMilliseconds, oldValue, Keys.quitGuardDoublePressMilliseconds)
        }
    }

    var quitGuardExtraModifier: QuitGuardModifier {
        didSet {
            guard quitGuardExtraModifier != oldValue else { return }
            defaults.set(quitGuardExtraModifier.rawValue, forKey: Keys.quitGuardExtraModifier)
        }
    }

    var quitGuardPolicy: QuitGuardPolicy {
        QuitGuardPolicy(
            defaultMode: quitGuardDefaultMode,
            overrides: quitGuardOverrides,
            protectsQuit: quitGuardProtectsQuit,
            protectsClose: quitGuardProtectsClose
        )
    }

    func resetToDefaults() {
        maximizeEnabled = DefaultValues.maximizeEnabled
        maximizeExceptions = DefaultValues.maximizeExceptions
        quitOnCloseEnabled = DefaultValues.quitOnCloseEnabled
        quitOnCloseApps = DefaultValues.quitOnCloseApps
        quitGuardEnabled = DefaultValues.quitGuardEnabled
        quitGuardProtectsQuit = DefaultValues.quitGuardProtectsQuit
        quitGuardProtectsClose = DefaultValues.quitGuardProtectsClose
        quitGuardDefaultMode = DefaultValues.quitGuardDefaultMode
        quitGuardOverrides = DefaultValues.quitGuardOverrides
        quitGuardHoldMilliseconds = DefaultValues.quitGuardHoldMilliseconds
        quitGuardDoublePressMilliseconds = DefaultValues.quitGuardDoublePressMilliseconds
        quitGuardExtraModifier = DefaultValues.quitGuardExtraModifier
    }

    // MARK: Storage

    enum Keys {
        static let maximizeEnabled = "wharf.windowBehavior.maximizeEnabled"
        static let maximizeExceptions = "wharf.windowBehavior.maximizeExceptions"
        static let quitOnCloseEnabled = "wharf.windowBehavior.quitOnCloseEnabled"
        static let quitOnCloseApps = "wharf.windowBehavior.quitOnCloseApps"
        static let quitGuardEnabled = "wharf.windowBehavior.quitGuardEnabled"
        static let quitGuardProtectsQuit = "wharf.windowBehavior.quitGuardProtectsQuit"
        static let quitGuardProtectsClose = "wharf.windowBehavior.quitGuardProtectsClose"
        static let quitGuardDefaultMode = "wharf.windowBehavior.quitGuardDefaultMode"
        static let quitGuardOverrides = "wharf.windowBehavior.quitGuardOverrides"
        static let quitGuardHoldMilliseconds = "wharf.windowBehavior.quitGuardHoldMilliseconds"
        static let quitGuardDoublePressMilliseconds = "wharf.windowBehavior.quitGuardDoublePressMilliseconds"
        static let quitGuardExtraModifier = "wharf.windowBehavior.quitGuardExtraModifier"
    }

    enum DefaultValues {
        static let maximizeEnabled = false
        static let maximizeExceptions: [String] = []
        static let quitOnCloseEnabled = false
        static let quitOnCloseApps: [String] = []
        static let quitGuardEnabled = false
        static let quitGuardProtectsQuit = true
        static let quitGuardProtectsClose = false
        static let quitGuardDefaultMode = QuitGuardMode.hold
        static let quitGuardOverrides: [String: QuitGuardMode] = [:]
        static let quitGuardHoldMilliseconds = 800.0
        static let quitGuardDoublePressMilliseconds = 600.0
        static let quitGuardExtraModifier = QuitGuardModifier.shift
    }

    @ObservationIgnored private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maximizeEnabled = defaults.object(forKey: Keys.maximizeEnabled) as? Bool ?? DefaultValues.maximizeEnabled
        maximizeExceptions = WindowBehaviorBundleList.sanitized(
            defaults.stringArray(forKey: Keys.maximizeExceptions) ?? DefaultValues.maximizeExceptions
        )
        quitOnCloseEnabled = defaults.object(forKey: Keys.quitOnCloseEnabled) as? Bool ?? DefaultValues.quitOnCloseEnabled
        quitOnCloseApps = WindowBehaviorBundleList.sanitized(
            defaults.stringArray(forKey: Keys.quitOnCloseApps) ?? DefaultValues.quitOnCloseApps
        )
        quitGuardEnabled = defaults.object(forKey: Keys.quitGuardEnabled) as? Bool ?? DefaultValues.quitGuardEnabled
        quitGuardProtectsQuit = defaults.object(forKey: Keys.quitGuardProtectsQuit) as? Bool
            ?? DefaultValues.quitGuardProtectsQuit
        quitGuardProtectsClose = defaults.object(forKey: Keys.quitGuardProtectsClose) as? Bool
            ?? DefaultValues.quitGuardProtectsClose
        quitGuardDefaultMode = defaults.string(forKey: Keys.quitGuardDefaultMode).flatMap(QuitGuardMode.init(rawValue:))
            ?? DefaultValues.quitGuardDefaultMode
        quitGuardOverrides = (defaults.dictionary(forKey: Keys.quitGuardOverrides) as? [String: String])?
            .compactMapValues(QuitGuardMode.init(rawValue:))
            ?? DefaultValues.quitGuardOverrides
        quitGuardHoldMilliseconds = QuitGuardStateMachine.clampedHold(
            defaults.object(forKey: Keys.quitGuardHoldMilliseconds) as? Double ?? DefaultValues.quitGuardHoldMilliseconds
        )
        quitGuardDoublePressMilliseconds = QuitGuardStateMachine.clampedDoublePress(
            defaults.object(forKey: Keys.quitGuardDoublePressMilliseconds) as? Double
                ?? DefaultValues.quitGuardDoublePressMilliseconds
        )
        quitGuardExtraModifier = defaults.string(forKey: Keys.quitGuardExtraModifier)
            .flatMap(QuitGuardModifier.init(rawValue:))
            ?? DefaultValues.quitGuardExtraModifier
    }

    private func store<T: Equatable>(_ value: T, _ oldValue: T, _ key: String) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
    }

    private func storeList(_ value: [String], _ oldValue: [String], _ key: String) {
        guard value != oldValue else { return }
        defaults.set(WindowBehaviorBundleList.sanitized(value), forKey: key)
    }
}
