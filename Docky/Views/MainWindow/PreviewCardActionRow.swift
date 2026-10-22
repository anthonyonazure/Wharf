//
//  PreviewCardActionRow.swift
//  Wharf
//
//  The compact row of buttons a hover preview card shows while the pointer is
//  over it: a Snap menu, minimize (or restore for a minimized window) and
//  close. Each acts on the card's own window, never the frontmost one.
//
//  Adapted from Vorssaint's dock preview actions
//  (https://github.com/vorssaint/vorssaint-utils, GPL-3.0-or-later,
//  Sources/Vorssaint/Services/DockPreview/DockPreviewService.swift).
//
//  The buttons cannot take keyboard focus: the preview panel never becomes
//  key, and each button is also marked unfocusable, so typing keeps going to
//  the app the user is working in.
//

import AppKit
import SwiftUI

struct PreviewCardActionRow: View {
    let window: AppWindow
    /// True while the Snap menu is open, so the parent keeps the row on
    /// screen after the pointer moves into the menu.
    @Binding var isMenuPresented: Bool

    @ObservedObject private var preview = WindowPreviewService.shared
    private var preferences = PreviewActionsPreferences.shared

    init(window: AppWindow, isMenuPresented: Binding<Bool>) {
        self.window = window
        self._isMenuPresented = isMenuPresented
    }

    var body: some View {
        let actions = PreviewActionsPolicy.visibleActions(
            settings: preferences.settings,
            isMinimized: window.isMinimized
        )
        if !actions.isEmpty {
            HStack(spacing: 4) {
                ForEach(actions, id: \.self) { action in
                    button(for: action)
                }
            }
        }
    }

    @ViewBuilder
    private func button(for action: PreviewCardAction) -> some View {
        switch action {
        case .snap:
            MoreActionsButton(
                systemImage: "rectangle.split.2x1",
                helpText: "Snap",
                onPresentationChanged: { presented in
                    isMenuPresented = presented
                    preview.setContextMenuPresented(presented)
                },
                actionProvider: { _ in snapActions() }
            )
            .focusable(false)
            .accessibilityLabel("Snap Window")
        case .minimize:
            PreviewActionCircleButton(systemImage: "minus", help: "Minimize") { run(.minimize) }
        case .restore:
            PreviewActionCircleButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Restore") { run(.restore) }
        case .close:
            PreviewActionCircleButton(systemImage: "xmark", help: "Close Window") { run(.close) }
        }
    }

    private func snapActions() -> [ContextAction] {
        PreviewActionsPolicy.snapChoices(displayCount: NSScreen.screens.count).map { snap in
            .action(snap.title, image: contextMenuSymbol(symbol(for: snap))) {
                // Close the preview first, as the window menu actions do, so
                // the panel is not over the window while it moves.
                WindowPreviewWindowController.shared.dismissCurrent()
                if WindowSnapService.shared.perform(snap, on: window) {
                    _ = WorkspaceService.shared.focus(window: window)
                }
            }
        }
    }

    private func symbol(for snap: WindowSnapAction) -> String {
        switch snap {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .maximize: "rectangle.fill"
        case .nextDisplay: "display.2"
        default: "rectangle"
        }
    }

    private func run(_ action: PreviewCardAction) {
        let workspace = WorkspaceService.shared
        let succeeded: Bool
        switch action {
        case .close: succeeded = workspace.close(window: window)
        case .minimize: succeeded = workspace.minimize(window: window)
        case .restore: succeeded = workspace.restoreMinimizedWindow(window)
        case .snap: return
        }

        switch PreviewActionsPolicy.outcome(after: action, succeeded: succeeded) {
        case .removeCard:
            preview.removeWindow(withIdentifier: window.windowIdentifier)
        case .dismissPreview:
            WindowPreviewWindowController.shared.dismissCurrent()
        case .keepCard:
            break
        }
    }
}

/// A small round glass button matching MoreActionsButton's look.
private struct PreviewActionCircleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }
}
