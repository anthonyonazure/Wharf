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
//  on one serial background queue (so at most one walk is ever in flight),
//  and is bounded in depth, accepted items, visited nodes and elapsed time.
//  A newer walk cancels the older one. Every element read gets its own short
//  messaging timeout, because a timeout set on the app element does not
//  carry over to the elements it returns. Every Accessibility value is type
//  checked before the cast, because a wrong cast on an AX value is a crash
//  rather than a nil.
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
    /// The process that owns the menu, checked again before pressing.
    let pid: pid_t
    let isDestructive: Bool
}

/// Cancels a walk that is no longer wanted, from any thread.
nonisolated final class CommandBarMenuWalk: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

nonisolated enum CommandBarMenus {
    private static let maximumDepth = 4
    private static let maximumItems = 400
    /// Disabled items, separators and submenus all cost reads, so the walk
    /// counts every node it touches, not only the commands it keeps.
    private static let maximumVisited = 2500
    private static let timeBudget: TimeInterval = 1.5
    private static let elementTimeout: Float = 0.25
    /// Menus nobody means to run from a search field.
    private static let skippedTopLevelTitles: Set<String> = ["Apple", "Window", "Help"]
    /// Serial, so closing and reopening the bar never stacks walks.
    private static let queue = DispatchQueue(label: "wharf.commandBar.menus", qos: .userInitiated)

    private struct Budget {
        let deadline: TimeInterval
        let walk: CommandBarMenuWalk
        var visited = 0

        var isExhausted: Bool {
            visited >= CommandBarMenus.maximumVisited
                || ProcessInfo.processInfo.systemUptime >= deadline
                || walk.isCancelled
        }
    }

    /// Walks `pid`'s menus on the background queue and hands the commands to
    /// `completion` on the main queue, unless `walk` was cancelled first.
    static func load(pid: pid_t, walk: CommandBarMenuWalk, completion: @escaping ([CommandBarMenuItem]) -> Void) {
        queue.async {
            guard !walk.isCancelled else { return }
            let items = items(for: pid, walk: walk)
            DispatchQueue.main.async {
                guard !walk.isCancelled else { return }
                completion(items)
            }
        }
    }

    /// The commands of `pid`, or nothing when Accessibility is not granted
    /// or the app has no menu bar. Blocking: call it on a background queue.
    static func items(for pid: pid_t, walk: CommandBarMenuWalk = CommandBarMenuWalk()) -> [CommandBarMenuItem] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, elementTimeout)
        guard let menuBar = copyElement(app, kAXMenuBarAttribute) else { return [] }
        AXUIElementSetMessagingTimeout(menuBar, elementTimeout)

        var budget = Budget(deadline: ProcessInfo.processInfo.systemUptime + timeBudget, walk: walk)
        var collected: [CommandBarMenuItem] = []
        for (index, menu) in children(of: menuBar, budget: &budget).enumerated() {
            guard !budget.isExhausted, collected.count < maximumItems else { break }
            guard let title = copyString(menu, kAXTitleAttribute), !title.isEmpty,
                  !skippedTopLevelTitles.contains(title) else { continue }
            // The application menu sits right after the Apple menu. Its Quit
            // is left out: the app row's own actions already offer it, behind
            // a confirmation, and it must never be a top hit for "qu".
            let isApplicationMenu = index == 1
            for child in children(of: menu, budget: &budget) {
                collect(child, path: [title], pid: pid, skipQuit: isApplicationMenu, into: &collected, depth: 1, budget: &budget)
                if collected.count >= maximumItems || budget.isExhausted { break }
            }
        }
        return collected
    }

    private static func collect(
        _ element: AXUIElement,
        path: [String],
        pid: pid_t,
        skipQuit: Bool,
        into collected: inout [CommandBarMenuItem],
        depth: Int,
        budget: inout Budget
    ) {
        guard depth <= maximumDepth, collected.count < maximumItems, !budget.isExhausted else { return }
        budget.visited += 1
        let role = copyString(element, kAXRoleAttribute)
        if role == kAXMenuRole as String {
            for child in children(of: element, budget: &budget) {
                collect(child, path: path, pid: pid, skipQuit: skipQuit, into: &collected, depth: depth + 1, budget: &budget)
            }
            return
        }
        guard role == kAXMenuItemRole as String,
              let title = copyString(element, kAXTitleAttribute),
              !title.isEmpty else { return }

        let submenus = children(of: element, budget: &budget)
        if !submenus.isEmpty {
            // A title that only opens another menu is not a command.
            for child in submenus {
                collect(child, path: path + [title], pid: pid, skipQuit: skipQuit, into: &collected, depth: depth + 1, budget: &budget)
            }
            return
        }
        guard isEnabled(element) else { return }
        if skipQuit, CommandBarRanking.words(CommandBarRanking.normalized(title)).contains("quit") { return }
        collected.append(CommandBarMenuItem(
            path: path,
            title: title,
            shortcut: shortcut(of: element),
            element: element,
            pid: pid,
            isDestructive: CommandBarSafety.isDestructive(title)
        ))
    }

    /// Checks a cached command just before it runs: still owned by the same
    /// process, same title, and enabled. Returns why not, or nil when it is
    /// safe to press. Blocking: call it on a background queue.
    static func revalidate(_ item: CommandBarMenuItem) -> String? {
        guard AXIsProcessTrusted() else { return "Accessibility is not granted." }
        AXUIElementSetMessagingTimeout(item.element, elementTimeout)
        var owner: pid_t = 0
        guard AXUIElementGetPid(item.element, &owner) == .success, owner == item.pid,
              copyString(item.element, kAXTitleAttribute) == item.title else {
            return "\(item.title) is no longer in the menu."
        }
        guard isEnabled(item.element) else {
            return "\(item.title) is not available right now."
        }
        return nil
    }

    /// Presses a menu command. The bar never activates Wharf, so the app
    /// that owns the menu is still in front and the command lands there.
    /// Blocking: call it on a background queue.
    static func press(_ item: CommandBarMenuItem) -> Bool {
        AXUIElementSetMessagingTimeout(item.element, elementTimeout * 2)
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    // MARK: - Accessibility reading

    /// Children in one bounded batch, never more than the budget has left.
    /// Each child gets its own messaging timeout before anything reads it.
    private static func children(of element: AXUIElement, budget: inout Budget) -> [AXUIElement] {
        let remaining = maximumVisited - budget.visited
        guard remaining > 0, !budget.isExhausted else { return [] }
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(remaining, 200), &raw) == .success,
              let raw, CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let elements = ((raw as NSArray) as? [AnyObject] ?? []).compactMap { object -> AXUIElement? in
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        for child in elements { AXUIElementSetMessagingTimeout(child, elementTimeout) }
        return elements
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

    /// Fails closed: an item whose enabled state cannot be read is treated
    /// as disabled.
    private static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let raw = copyValue(element, kAXEnabledAttribute),
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return false }
        return (raw as? Bool) ?? false
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
