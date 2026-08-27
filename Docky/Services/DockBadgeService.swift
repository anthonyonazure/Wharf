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
    // Wharf: this walked the system Dock's whole accessibility tree on the
    // main thread every two seconds. Roughly two cross-process calls per dock
    // item, forever, to read numbers that change a few times an hour. The walk
    // now runs off the main thread and slows down while nothing is changing.
    private let minimumInterval: TimeInterval = 2
    private let maximumInterval: TimeInterval = 15
    private var currentInterval: TimeInterval = 2
    private let walkQueue = DispatchQueue(label: "wharf.dock-badge.walk", qos: .utility)
    private var isWalking = false
    private var cancellables: Set<AnyCancellable> = []

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
        scheduleNext()

        // A badge that matters almost always arrives with an app doing
        // something, so treat any launch, quit or switch as a reason to look
        // again promptly instead of waiting out a stretched interval.
        let center = NSWorkspace.shared.notificationCenter
        for note in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.publisher(for: note)
                .sink { [weak self] _ in self?.quicken() }
                .store(in: &cancellables)
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let next = Timer(timeInterval: currentInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleNext()
            }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func quicken() {
        guard currentInterval != minimumInterval else { return }
        currentInterval = minimumInterval
        scheduleNext()
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
        guard !Self.screenIsLocked() else { return }
        guard !isWalking else { return }
        guard let dock = dockApplicationElement() else { return }
        isWalking = true

        // The walk is nothing but accessibility reads, and every one of them
        // is a blocking trip into the Dock's process. Off the main thread it
        // cannot stutter the tiles it is feeding.
        walkQueue.async { [weak self] in
            guard let self else { return }
            var scanned: [String: String] = [:]
            for item in self.dockItems(in: dock) {
                guard let badge = self.trimmedBadge(from: item),
                      let url = self.copyAttribute(item, kAXURLAttribute) as? URL else { continue }
                scanned[url.path] = badge
            }
            Task { @MainActor in
                self.isWalking = false
                self.apply(scannedByPath: scanned)
            }
        }
    }

    /// True while the screen is locked. Nothing is drawn then, so nothing
    /// needs to be read.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        return false
    }

    private func apply(scannedByPath: [String: String]) {
        var newBadges: [String: String] = [:]
        for (path, badge) in scannedByPath {
            guard let bundleID = bundleIdentifier(forPath: path) else { continue }
            newBadges[bundleID] = badge
        }

        if newBadges == badgesByBundleID {
            currentInterval = min(currentInterval * 1.5, maximumInterval)
        }

        if newBadges != badgesByBundleID {
            currentInterval = minimumInterval
            // Wharf: a badge that appears or grows on an app you are not
            // looking at is the closest public signal to "this app wants your
            // attention". macOS exposes no API for another process calling
            // requestUserAttention, so this stands in for the Dock's bounce.
            for (bundleID, badge) in newBadges {
                let previous = badgesByBundleID[bundleID]
                guard previous != badge else { continue }
                // Any change counts. Badges are not always numbers — Messages
                // and some apps use a dot or a glyph — so an increase test
                // silently ignores exactly those apps.
                let numericDrop = (Int(badge).map { current in
                    previous.flatMap(Int.init).map { $0 > current } ?? false
                }) ?? false
                if !numericDrop {
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

    private func bundleIdentifier(forPath path: String) -> String? {
        if let cached = bundleIDByPath[path] { return cached.isEmpty ? nil : cached }
        let url = URL(fileURLWithPath: path)
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
