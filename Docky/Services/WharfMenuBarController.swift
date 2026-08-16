//
//  WharfMenuBarController.swift
//  Wharf
//
//  A menu bar item for the switches you need to reach fast.
//
//  The keyboard translation rewrites input system-wide. Anything that can make
//  a keyboard behave unexpectedly needs an off switch that does not itself
//  require using the keyboard to navigate a settings window.
//

import AppKit
import Combine

@MainActor
final class WharfMenuBarController: NSObject {
    static let shared = WharfMenuBarController()

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "dock.rectangle",
            accessibilityDescription: "Wharf"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// Rebuilt on open so the checkmarks and the layout list are current
    /// without needing to observe every preference.
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let preferences = DockyPreferences.shared

        let keyboardItem = NSMenuItem(
            title: "Windows Keyboard Mode",
            action: #selector(toggleWindowsKeyboard),
            keyEquivalent: ""
        )
        keyboardItem.target = self
        keyboardItem.state = preferences.windowsKeyboardMode ? .on : .off
        menu.addItem(keyboardItem)

        if preferences.windowsKeyboardMode, !AXIsProcessTrusted() {
            let warning = NSMenuItem(
                title: "  Blocked: grant Accessibility",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
        }

        let snipItem = NSMenuItem(
            title: "Win+Shift+S Screen Snip",
            action: #selector(toggleSnip),
            keyEquivalent: ""
        )
        snipItem.target = self
        snipItem.state = preferences.windowsKeyboardSnipShortcut ? .on : .off
        snipItem.isEnabled = preferences.windowsKeyboardMode
        menu.addItem(snipItem)

        menu.addItem(.separator())

        let layouts = WorkspaceLayoutService.shared.layouts
        if layouts.isEmpty {
            let empty = NSMenuItem(title: "No Saved Layouts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for layout in layouts {
                let item = NSMenuItem(
                    title: "Restore \(layout.name)",
                    action: #selector(restoreLayout(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = layout.id
                menu.addItem(item)
            }
        }

        if WorkspaceLayoutService.shared.undoSnapshot != nil {
            let undo = NSMenuItem(
                title: "Undo Last Restore",
                action: #selector(undoRestore),
                keyEquivalent: ""
            )
            undo.target = self
            menu.addItem(undo)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Wharf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleWindowsKeyboard() {
        DockyPreferences.shared.windowsKeyboardMode.toggle()
    }

    @objc private func toggleSnip() {
        DockyPreferences.shared.windowsKeyboardSnipShortcut.toggle()
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let layout = WorkspaceLayoutService.shared.layouts.first(where: { $0.id == id }) else { return }
        WorkspaceLayoutService.shared.restore(layout)
    }

    @objc private func undoRestore() {
        WorkspaceLayoutService.shared.undoLastRestore()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

extension WharfMenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
