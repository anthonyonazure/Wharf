//
//  PreviewActionsLogic.swift
//  Wharf
//
//  Pure decisions behind two dock features, kept free of AppKit so
//  scripts/test-preview-actions.sh can check them without any windows:
//
//   - Preview Actions: which buttons a hover preview card shows (close,
//     minimize or restore, a small Snap menu) and what happens to the card
//     after each one.
//   - Layouts in dock menus: the rows of the Layouts submenu and the name
//     offered when saving the current arrangement.
//
//  The per-window preview actions follow Vorssaint's dock preview
//  (https://github.com/vorssaint/vorssaint-utils, GPL-3.0-or-later,
//  Sources/Vorssaint/Services/DockPreview): close and minimize act on the
//  hovered window itself, and a minimized window offers to come back instead
//  of being minimized again.
//

import Foundation

// MARK: - Preview actions

/// One button in a preview card's hover row.
nonisolated enum PreviewCardAction: String, CaseIterable, Equatable {
    case snap
    case minimize
    case restore
    case close
}

/// What the preview does with a card once its action has run.
nonisolated enum PreviewCardOutcome: Equatable {
    /// The window is gone from view; drop its card and keep the rest open.
    case removeCard
    /// The card still describes the window correctly; leave everything.
    case keepCard
    /// The user is moving to the window; close the preview.
    case dismissPreview
}

nonisolated struct PreviewActionsSettings: Equatable {
    var showsClose: Bool
    var showsMinimize: Bool
    var showsSnapMenu: Bool
}

nonisolated enum PreviewActionsPolicy {
    /// The snap choices offered on a card, in menu order. Next Display only
    /// appears when there is another display to go to.
    static func snapChoices(displayCount: Int) -> [WindowSnapAction] {
        var choices: [WindowSnapAction] = [.leftHalf, .rightHalf, .maximize]
        if displayCount > 1 { choices.append(.nextDisplay) }
        return choices
    }

    /// Buttons for one card, left to right. A minimized window has no frame
    /// to snap, so it gets Restore in place of Snap and Minimize.
    static func visibleActions(
        settings: PreviewActionsSettings,
        isMinimized: Bool
    ) -> [PreviewCardAction] {
        var actions: [PreviewCardAction] = []
        if isMinimized {
            if settings.showsMinimize { actions.append(.restore) }
        } else {
            if settings.showsSnapMenu { actions.append(.snap) }
            if settings.showsMinimize { actions.append(.minimize) }
        }
        if settings.showsClose { actions.append(.close) }
        return actions
    }

    /// What to do with the card after `action` succeeded.
    ///
    /// Minimizing keeps the card only when previews list minimized windows,
    /// and even then the card's dimmed look is not refreshed until the next
    /// hover, so it is dropped either way: a card that still looks live for a
    /// window that just left the screen reads as a failed click.
    static func outcome(after action: PreviewCardAction, succeeded: Bool) -> PreviewCardOutcome {
        guard succeeded else { return .keepCard }
        switch action {
        case .close, .minimize: return .removeCard
        case .restore, .snap: return .dismissPreview
        }
    }
}

// MARK: - Layouts in dock menus

/// A row in the Layouts submenu. The view layer turns these into NSMenuItem
/// or ContextAction values so the status item and the dock menus agree.
nonisolated enum LayoutMenuRow: Equatable {
    case restore(id: String, title: String)
    case empty
    case divider
    case save
    case undo
}

nonisolated enum LayoutMenuModel {
    static let emptyTitle = "No Saved Layouts"
    static let saveTitle = "Save Current Layout..."
    static let undoTitle = "Undo Last Restore"
    static let launchSuffix = " and Open Missing Apps"

    /// Rows for the submenu: every saved layout in the user's order, then
    /// Save, then Undo when a restore can be undone.
    static func rows(layouts: [(id: String, name: String)], canUndo: Bool) -> [LayoutMenuRow] {
        var rows: [LayoutMenuRow] = layouts.isEmpty
            ? [.empty]
            : layouts.map { .restore(id: $0.id, title: $0.name) }
        rows.append(.divider)
        rows.append(.save)
        if canUndo { rows.append(.undo) }
        return rows
    }

    /// Title for a layout row. With Option held the row also opens the apps
    /// the layout needs, and says so.
    static func restoreTitle(_ name: String, launchesMissingApps: Bool) -> String {
        launchesMissingApps ? name + launchSuffix : name
    }

    /// A name the save prompt can offer: "Layout 1", or the next number not
    /// already taken. Comparison ignores case so "layout 1" counts as taken.
    static func suggestedName(existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var number = 1
        while taken.contains("layout \(number)") { number += 1 }
        return "Layout \(number)"
    }

    /// The name to save under, or nil when it is blank. Long names are cut so
    /// a pasted paragraph does not become a menu item wider than the screen.
    static func validatedName(_ raw: String, maxLength: Int = 60) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Capture replaces a layout with exactly this name, so the prompt warns
    /// before overwriting it.
    static func replacesExisting(_ name: String, existing: [String]) -> Bool {
        existing.contains(name)
    }
}
