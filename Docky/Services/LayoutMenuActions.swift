//
//  LayoutMenuActions.swift
//  Wharf
//
//  The Layouts submenu shared by the dock's right-click menus and the Wharf
//  menu bar item: restore a saved layout in one click, save the current
//  arrangement under a name, undo the last restore.
//
//  Restore goes through WorkspaceLayoutService exactly as the Layouts widget
//  does: a plain restore, or launchAndRestore when Option is held, which opens
//  missing apps and waits for their windows before placing anything.
//

import AppKit

@MainActor
enum LayoutMenuActions {
    private static var service: WorkspaceLayoutService { .shared }

    // MARK: Dock menus

    /// The Layouts submenu as a dock context menu entry, or nothing when the
    /// user turned it off. Built lazily so the list is current when opened.
    static func dockMenuEntries() -> [ContextAction] {
        guard PreviewActionsPreferences.shared.showsLayoutsInDockMenus else { return [] }
        return [
            .lazySubmenu(String(localized: "Layouts"), image: contextMenuSymbol("rectangle.3.group")) {
                submenuActions()
            },
        ]
    }

    private static func submenuActions() -> [ContextAction] {
        // Each layout is a pair of native alternates, as in the menu bar
        // item: AppKit swaps the row while Option is held, so the label the
        // user clicks is always the action that runs.
        rows().flatMap { row -> [ContextAction] in
            switch row {
            case .restore(let id, let title):
                return [
                    .action(LayoutMenuModel.restoreTitle(title, launchesMissingApps: false)) {
                        restore(id: id, launchingMissingApps: false)
                    },
                    .action(
                        LayoutMenuModel.restoreTitle(title, launchesMissingApps: true),
                        alternateModifiers: .option
                    ) {
                        restore(id: id, launchingMissingApps: true)
                    },
                ]
            case .empty:
                return [.action(String(localized: "No Saved Layouts")) {}]
            case .divider:
                return [.divider]
            case .save:
                return [.action(String(localized: "Save Current Layout...")) { promptToSave() }]
            case .undo:
                return [.action(String(localized: "Undo Last Restore")) { service.undoLastRestore() }]
            }
        }
    }

    // MARK: Menu bar item

    /// A Layouts submenu item for an NSMenu. Option shows the launching
    /// variant of each layout as a standard alternate item.
    static func menuBarItem() -> NSMenuItem? {
        guard PreviewActionsPreferences.shared.showsLayoutsInDockMenus else { return nil }
        let submenu = NSMenu()
        for row in rows() {
            switch row {
            case .restore(let id, let title):
                let primary = MenuItem(title: title) { restore(id: id, launchingMissingApps: false) }
                primary.keyEquivalentModifierMask = []
                submenu.addItem(primary)
                let alternate = MenuItem(title: LayoutMenuModel.restoreTitle(title, launchesMissingApps: true)) {
                    restore(id: id, launchingMissingApps: true)
                }
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = .option
                submenu.addItem(alternate)
            case .empty:
                let empty = NSMenuItem(title: LayoutMenuModel.emptyTitle, action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            case .divider:
                submenu.addItem(.separator())
            case .save:
                submenu.addItem(MenuItem(title: LayoutMenuModel.saveTitle) { promptToSave() })
            case .undo:
                submenu.addItem(MenuItem(title: LayoutMenuModel.undoTitle) { service.undoLastRestore() })
            }
        }
        let item = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    // MARK: Actions

    private static func rows() -> [LayoutMenuRow] {
        LayoutMenuModel.rows(
            layouts: service.layouts.map { (id: $0.id, name: $0.name) },
            canUndo: service.undoSnapshot != nil
        )
    }

    static func restore(id: String, launchingMissingApps: Bool) {
        guard let layout = service.layouts.first(where: { $0.id == id }) else { return }
        if launchingMissingApps {
            service.launchAndRestore(layout)
        } else {
            service.restore(layout)
        }
    }

    /// Asks for a name and captures the current arrangement under it.
    ///
    /// Deferred to the next run loop turn so the menu has closed first, and
    /// Wharf is activated because a non-activating app's alert field can not
    /// take typing.
    static func promptToSave() {
        DispatchQueue.main.async {
            let existing = service.layouts.map(\.name)

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = LayoutMenuModel.suggestedName(existing: existing)

            let alert = NSAlert()
            alert.messageText = "Save Current Layout"
            alert.informativeText = "Records where every visible window is, so you can put them back from the dock."
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn,
                  let name = LayoutMenuModel.validatedName(field.stringValue) else { return }

            // Names read again now: the alert is modal, and another save may
            // have landed while it was open.
            if LayoutMenuModel.replacesExisting(name, existing: service.layouts.map(\.name)) {
                let confirm = NSAlert()
                confirm.messageText = "Replace \u{201C}\(name)\u{201D}?"
                confirm.informativeText = "A layout with this name already exists. Saving replaces it with the current arrangement."
                confirm.addButton(withTitle: "Replace")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }

            service.capture(name: name)
        }
    }
}

/// An NSMenuItem that runs a closure, so a menu built outside a target object
/// needs no selector plumbing.
private final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
