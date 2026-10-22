//
//  CommandBarPreferences.swift
//  Wharf
//
//  Settings for the Command Bar. Kept in its own store, with the same
//  Keys and DefaultValues pattern as DockyPreferences, so the feature adds
//  nothing to that shared file. Every key starts with "wharf.commandBar.".
//

import AppKit
import Foundation
import Observation

@Observable
final class CommandBarPreferences {
    static let shared = CommandBarPreferences()

    /// What the bar searches. Each one has its own switch in the pane.
    enum Source: String, CaseIterable, Identifiable, Codable {
        case apps, windows, files, menus, snap, calculator, units

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apps: "Apps"
            case .windows: "Open Windows"
            case .files: "Files"
            case .menus: "Menu Commands"
            case .snap: "Window Snapping"
            case .calculator: "Calculator"
            case .units: "Unit Conversion"
            }
        }

        var detail: String {
            switch self {
            case .apps: "Installed and running apps."
            case .windows: "Open windows of every app. Choosing one brings it to the front."
            case .files: "Files on this Mac found by Spotlight, local disks only."
            case .menus: "Commands in the menu bar of the app in front. Choosing one runs it."
            case .snap: "Type a layout such as left half or maximize to snap the window in front."
            case .calculator: "Type arithmetic such as 2 * (3 + 4) to see the answer."
            case .units: "Type a conversion such as 100 km to mi or 20 c to f."
            }
        }

        var symbolName: String {
            switch self {
            case .apps: "app"
            case .windows: "macwindow.on.rectangle"
            case .files: "doc"
            case .menus: "filemenu.and.selection"
            case .snap: "rectangle.split.2x1"
            case .calculator: "plus.forwardslash.minus"
            case .units: "ruler"
            }
        }

        /// Sources that read or drive other apps through Accessibility.
        var needsAccessibility: Bool {
            self == .windows || self == .menus || self == .snap
        }
    }

    static let maxResultsRange = 3...20

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Keys.enabled)
        }
    }

    var shortcut: KeyboardShortcut {
        didSet {
            guard shortcut != oldValue else { return }
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Keys.shortcut)
            }
        }
    }

    /// Stored as the switched-off set, so a source added later starts on.
    private(set) var disabledSources: Set<Source> {
        didSet {
            guard disabledSources != oldValue else { return }
            defaults.set(disabledSources.map(\.rawValue).sorted(), forKey: Keys.disabledSources)
        }
    }

    var maxResults: Int {
        didSet {
            let clamped = min(max(maxResults, Self.maxResultsRange.lowerBound), Self.maxResultsRange.upperBound)
            if clamped != maxResults {
                maxResults = clamped
                return
            }
            guard maxResults != oldValue else { return }
            defaults.set(maxResults, forKey: Keys.maxResults)
        }
    }

    /// What was chosen and when, for ranking. Local to this Mac.
    private(set) var recency: CommandBarRecency {
        didSet {
            guard recency != oldValue else { return }
            if recency.entries.isEmpty {
                defaults.removeObject(forKey: Keys.recency)
            } else if let data = try? JSONEncoder().encode(recency) {
                defaults.set(data, forKey: Keys.recency)
            }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? DefaultValues.enabled
        shortcut = defaults.data(forKey: Keys.shortcut)
            .flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) }
            ?? DefaultValues.shortcut
        disabledSources = Set((defaults.stringArray(forKey: Keys.disabledSources) ?? []).compactMap(Source.init(rawValue:)))
        let storedMax = defaults.object(forKey: Keys.maxResults) as? Int ?? DefaultValues.maxResults
        maxResults = min(max(storedMax, Self.maxResultsRange.lowerBound), Self.maxResultsRange.upperBound)
        recency = defaults.data(forKey: Keys.recency)
            .flatMap { try? JSONDecoder().decode(CommandBarRecency.self, from: $0) }
            ?? CommandBarRecency()
    }

    func isOn(_ source: Source) -> Bool {
        !disabledSources.contains(source)
    }

    func setSource(_ source: Source, on: Bool) {
        if on {
            disabledSources.remove(source)
        } else {
            disabledSources.insert(source)
        }
    }

    func recordUse(_ key: String) {
        var updated = recency
        updated.record(key, at: Date())
        recency = updated
    }

    func clearHistory() {
        recency = CommandBarRecency()
    }

    func resetToDefaults() {
        enabled = DefaultValues.enabled
        shortcut = DefaultValues.shortcut
        disabledSources = []
        maxResults = DefaultValues.maxResults
    }

    private enum Keys {
        static let enabled = "wharf.commandBar.enabled"
        static let shortcut = "wharf.commandBar.shortcut"
        static let disabledSources = "wharf.commandBar.disabledSources"
        static let maxResults = "wharf.commandBar.maxResults"
        static let recency = "wharf.commandBar.recency"
    }

    enum DefaultValues {
        static let enabled = false
        /// Option-Space. Nothing in Wharf uses it; it only takes effect
        /// once the bar is switched on, and the pane says so when another
        /// launcher already holds it.
        static let shortcut = KeyboardShortcut(keyCode: 49, modifierFlags: [.option])
        static let maxResults = 8
    }
}
