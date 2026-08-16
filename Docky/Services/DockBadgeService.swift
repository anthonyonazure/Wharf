//
//  DockBadgeService.swift
//  Docky
//
//  Reads notification badges (the red number on Mail, Messages, etc.) for
//  running apps and republishes them keyed by bundle identifier so tiles can
//  draw their own badge.
//
//  Source of truth: the system Dock. Each app sets its badge on its own dock
//  tile, and only the Dock process aggregates them, there's no public API to
//  read another app's badge directly. We read the Dock's accessibility tree
//  instead: every dock item exposes `AXStatusLabel` (the badge text) and an
//  `AXURL` (the .app location) we map back to a bundle id. This works even
//  when the system Dock is auto-hidden, since the Dock process and its AX
//  tree stay alive regardless of visibility.
//

import AppKit
import ApplicationServices
import Combine

@MainActor
final class DockBadgeService: ObservableObject {
    static let shared = DockBadgeService()

    /// Badge text per bundle identifier, e.g. ["com.apple.mail": "5"].
    /// Apps with no badge are absent from the map.
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    /// How often we re-read the Dock's AX tree. Badge changes (new mail,
    /// etc.) arrive at unpredictable times and the Dock itself updates
    /// asynchronously, so polling is the pragmatic approach. The read is
    /// cheap (a few AX attribute copies per dock item).
    private let pollInterval: TimeInterval = 2

    private var timer: Timer?
    /// Caches AXURL path -> bundle id so we don't rebuild a `Bundle` for
    /// every item on every poll.
    private var bundleIDByPath: [String: String] = [:]

    private init() {}

    func badge(forBundleIdentifier bundleIdentifier: String) -> String? {
        badgesByBundleID[bundleIdentifier]
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func refresh() {
        guard AXIsProcessTrusted() else {
            if !badgesByBundleID.isEmpty { badgesByBundleID = [:] }
            return
        }
        guard let dock = dockApplicationElement() else { return }

        var newBadges: [String: String] = [:]
        for item in dockItems(in: dock) {
            guard let badge = trimmedBadge(from: item),
                  let bundleID = bundleIdentifier(for: item) else { continue }
            newBadges[bundleID] = badge
        }

        if newBadges != badgesByBundleID {
            // Wharf: a badge that appears or grows on an app you are not
            // looking at is the closest public signal to "this app wants your
            // attention". macOS exposes no API for another process calling
            // requestUserAttention, so this stands in for the Dock's bounce.
            for (bundleID, badge) in newBadges {
                let previous = badgesByBundleID[bundleID]
                guard previous != badge else { continue }
                let grew = (Int(badge) ?? 0) > (previous.flatMap(Int.init) ?? 0)
                if previous == nil || grew {
                    Task { @MainActor in
                        AppActivityService.shared.noteAttentionRequested(bundleIdentifier: bundleID)
                    }
                }
            }

            badgesByBundleID = newBadges
        }
    }

    // MARK: - AX traversal

    private func dockApplicationElement() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first else { return nil }
        return AXUIElementCreateApplication(dock.processIdentifier)
    }

    /// The dock's items live inside its first `AXList` child. Returns that
    /// list's children (the individual app / folder / minimized-window items).
    private func dockItems(in dock: AXUIElement) -> [AXUIElement] {
        for child in children(of: dock) where role(of: child) == (kAXListRole as String) {
            return children(of: child)
        }
        return []
    }

    private func bundleIdentifier(for item: AXUIElement) -> String? {
        guard let url = copyAttribute(item, kAXURLAttribute) as? URL else { return nil }
        let path = url.path
        if let cached = bundleIDByPath[path] { return cached.isEmpty ? nil : cached }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        bundleIDByPath[path] = bundleID ?? ""  // cache misses too, to avoid re-probing
        return bundleID
    }

    /// `AXStatusLabel` holds the badge string the Dock paints (e.g. "5",
    /// "99+"). Empty / whitespace means no badge.
    private func trimmedBadge(from item: AXUIElement) -> String? {
        guard let label = copyAttribute(item, "AXStatusLabel" as CFString) as? String else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - AX helpers

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func role(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute as CFString) as? String
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        copyAttribute(element, attribute as CFString)
    }
}
