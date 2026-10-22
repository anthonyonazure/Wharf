//
//  PreviewActionsPreferences.swift
//  Wharf
//
//  Switches for the buttons on hover preview cards and for the Layouts
//  submenu in the dock's menus. Kept apart from DockyPreferences so the
//  feature stays in its own files; same Keys and DefaultValues layout and the
//  same UserDefaults domain, under the `wharf.previewActions.` prefix.
//
//  Everything here defaults on: each button only acts on the window the user
//  is pointing at, and the menu only adds a submenu.
//

import Foundation
import Observation

@Observable
final class PreviewActionsPreferences {
    static let shared = PreviewActionsPreferences()

    var showsClose: Bool {
        didSet { store(showsClose, oldValue, Keys.showsClose) }
    }

    var showsMinimize: Bool {
        didSet { store(showsMinimize, oldValue, Keys.showsMinimize) }
    }

    var showsSnapMenu: Bool {
        didSet { store(showsSnapMenu, oldValue, Keys.showsSnapMenu) }
    }

    /// The Layouts submenu in the dock's menus and the Wharf menu bar item.
    var showsLayoutsInDockMenus: Bool {
        didSet { store(showsLayoutsInDockMenus, oldValue, Keys.showsLayoutsInDockMenus) }
    }

    var settings: PreviewActionsSettings {
        PreviewActionsSettings(showsClose: showsClose, showsMinimize: showsMinimize, showsSnapMenu: showsSnapMenu)
    }

    var anyPreviewActionOn: Bool { showsClose || showsMinimize || showsSnapMenu }

    enum Keys {
        static let showsClose = "wharf.previewActions.showsClose"
        static let showsMinimize = "wharf.previewActions.showsMinimize"
        static let showsSnapMenu = "wharf.previewActions.showsSnapMenu"
        static let showsLayoutsInDockMenus = "wharf.previewActions.showsLayoutsInDockMenus"
    }

    enum DefaultValues {
        static let showsClose = true
        static let showsMinimize = true
        static let showsSnapMenu = true
        static let showsLayoutsInDockMenus = true
    }

    @ObservationIgnored private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsClose = defaults.object(forKey: Keys.showsClose) as? Bool ?? DefaultValues.showsClose
        showsMinimize = defaults.object(forKey: Keys.showsMinimize) as? Bool ?? DefaultValues.showsMinimize
        showsSnapMenu = defaults.object(forKey: Keys.showsSnapMenu) as? Bool ?? DefaultValues.showsSnapMenu
        showsLayoutsInDockMenus = defaults.object(forKey: Keys.showsLayoutsInDockMenus) as? Bool
            ?? DefaultValues.showsLayoutsInDockMenus
    }

    private func store<T: Equatable>(_ value: T, _ oldValue: T, _ key: String) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
    }
}
