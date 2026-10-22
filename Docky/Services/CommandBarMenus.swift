//
//  CommandBarMenus.swift
//  Wharf
//
//  Reads the menu bar of the app in front so the Command Bar can search and
//  run its commands.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later, Copyright (C) 2026 Vorssaint), CommandBarMenus.swift.
//  Wharf is GPL-3.0 as well.
//
//  The walk asks for children rather than opening any menu on screen, runs
//  off the main thread, and is bounded in depth and item count. Every
//  Accessibility value is type checked before the cast, because a wrong cast
//  on an AX value is a crash rather than a nil.
//

import AppKit
import ApplicationServices

nonisolated struct CommandBarMenuItem: @unchecked Sendable {
    /// Menu titles from the bar down to the parent, for example ["Format", "Font"].
    let path: [String]
    let title: String
    /// The item's own shortcut as the menu writes it, when it has one.
    let shortcut: String?
    let element: AXUIElement
}

nonisolated enum CommandBarMenus {
    private static let maximumDepth = 4
    private static let maximumItems = 400
    /// Menus nobody means to run from a search field.
    private static let skippedTopLevelTitles: Set<String> = ["Apple", "Window", "Help"]

    /// The commands of `pid`, or nothing when Accessibility is not granted
    /// or the app has no menu bar. Blocking: call it on a background queue.
    static func items(for pid: pid_t) -> [CommandBarMenuItem] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hold the walk.
        AXUIElementSetMessagingTimeout(app, 0.35)
        guard let menuBar = copyElement(app, kAXMenuBarAttribute) else { return [] }

        var collected: [CommandBarMenuItem] = []
        for menu in children(of: menuBar) {
            guard let title = copyString(menu, kAXTitleAttribute), !title.isEmpty,
                  !skippedTopLevelTitles.contains(title) else { continue }
            for child in children(of: menu) {
                collect(child, path: [title], into: &collected, depth: 1)
                if collected.count >= maximumItems { return collected }
            }
        }
        return collected
    }

    private static func collect(
        _ element: AXUIElement,
        path: [String],
        into collected: inout [CommandBarMenuItem],
        depth: Int
    ) {
        guard depth <= maximumDepth, collected.count < maximumItems else { return }
        let role = copyString(element, kAXRoleAttribute)
        if role == kAXMenuRole as String {
            for child in children(of: element) {
                collect(child, path: path, into: &collected, depth: depth + 1)
            }
            return
        }
        guard role == kAXMenuItemRole as String,
              let title = copyString(element, kAXTitleAttribute),
              !title.isEmpty else { return }

        let submenus = children(of: element)
        if !submenus.isEmpty {
            // A title that only opens another menu is not a command.
            for child in submenus {
                collect(child, path: path + [title], into: &collected, depth: depth + 1)
            }
            return
        }
        guard isEnabled(element) else { return }
        collected.append(CommandBarMenuItem(
            path: path,
            title: title,
            shortcut: shortcut(of: element),
            element: element
        ))
    }

    /// Presses a menu command. The bar never activates Wharf, so the app
    /// that owns the menu is still in front and the command lands there.
    @discardableResult
    static func press(_ item: CommandBarMenuItem) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    // MARK: - Accessibility reading

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyValue(element, kAXChildrenAttribute),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyValue(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyValue(element, attribute),
              CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let raw = copyValue(element, kAXEnabledAttribute),
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return true }
        return (raw as? Bool) ?? true
    }

    /// The shortcut written the way menus write it, from the command
    /// character and the classic Carbon modifier mask (shift bit 0, option
    /// bit 1, control bit 2, and bit 3 set means no Command).
    private static func shortcut(of element: AXUIElement) -> String? {
        guard let character = copyString(element, "AXMenuItemCmdChar"), !character.isEmpty else { return nil }
        var modifiers = 0
        if let raw = copyValue(element, "AXMenuItemCmdModifiers"), CFGetTypeID(raw) == CFNumberGetTypeID() {
            modifiers = (raw as? Int) ?? 0
        }
        var glyphs = ""
        if modifiers & 0x04 != 0 { glyphs += "⌃" }
        if modifiers & 0x02 != 0 { glyphs += "⌥" }
        if modifiers & 0x01 != 0 { glyphs += "⇧" }
        if modifiers & 0x08 == 0 { glyphs += "⌘" }
        return glyphs + character.uppercased()
    }
}
