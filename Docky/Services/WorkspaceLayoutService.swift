//
//  WorkspaceLayoutService.swift
//  Wharf
//
//  Saved window layouts: capture where every window sits across every display,
//  then put them all back with one click.
//
//  This is the payoff of running a dock on every screen. Wharf already knows
//  every window and which display it is on, and it can already move windows to
//  keep them off the dock strip. Layouts are those two capabilities pointed at
//  the actual cost of a multi-monitor desk, which is not launching apps — it is
//  arranging them again every time the task changes.
//

import AppKit
import Combine

struct WindowPlacement: Codable, Equatable {
    let bundleIdentifier: String
    /// Matched on restore. Titles change (documents, tabs), so this is a hint
    /// rather than a key.
    let windowTitle: String
    /// Frame in NSScreen coordinates, stored relative to nothing — absolute
    /// global position, which is what makes multi-display restore work.
    let frame: CGRect
    /// Persistent UUID of the display this window was on. Survives reboots and
    /// cable swaps, unlike CGDirectDisplayID.
    let displayUUID: String?
}

struct WorkspaceLayout: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var placements: [WindowPlacement]
    /// Apps that were running when the layout was captured, so restore can
    /// offer to launch what is missing.
    var bundleIdentifiers: [String]
}

@MainActor
final class WorkspaceLayoutService: ObservableObject {
    static let shared = WorkspaceLayoutService()

    @Published private(set) var layouts: [WorkspaceLayout] = []

    /// Set while a restore is running so the dock's own window-reservation
    /// logic does not fight the placement pass by shoving windows back off
    /// the dock strip mid-restore.
    @Published private(set) var isRestoring = false

    private let defaultsKey = "wharf.workspaceLayouts"

    private init() {
        load()
    }

    // MARK: - Capture

    /// Records every visible window's position, size and display.
    ///
    /// Minimized windows are skipped: they have no meaningful frame, and
    /// restoring one would need un-minimizing it, which changes what the user
    /// asked to capture.
    func capture(name: String) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }

        var placements: [WindowPlacement] = []
        var bundles = Set<String>()

        for window in WindowRegistry.shared.windows where !window.isMinimized {
            guard let axFrame = window.frame, axFrame.width > 0, axFrame.height > 0 else { continue }

            // AX reports a top-left origin with Y increasing downward; every
            // frame stored here is in NSScreen space so restore can compare it
            // against screens directly.
            let nsFrame = CGRect(
                x: axFrame.minX,
                y: primaryHeight - axFrame.maxY,
                width: axFrame.width,
                height: axFrame.height
            )

            placements.append(
                WindowPlacement(
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.windowTitle,
                    frame: nsFrame,
                    displayUUID: Self.displayUUID(containing: nsFrame)
                )
            )
            bundles.insert(window.bundleIdentifier)
        }

        guard !placements.isEmpty else { return }

        let layout = WorkspaceLayout(
            id: UUID().uuidString,
            name: name,
            placements: placements,
            bundleIdentifiers: Array(bundles).sorted()
        )

        // Replacing by name makes re-capturing an existing layout the obvious
        // gesture: save over "work" rather than accumulating "work 2".
        if let index = layouts.firstIndex(where: { $0.name == name }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
        save()
    }

    // MARK: - Restore

    /// Puts every window back where the layout says it belongs.
    ///
    /// Matching is deliberately forgiving. A window's title changes as you work
    /// (a document is renamed, a browser tab switches), so an exact-title
    /// requirement would restore almost nothing after a real day's use. Windows
    /// are matched per app: exact title first, then by position in the app's
    /// window list.
    @discardableResult
    func restore(_ layout: WorkspaceLayout) -> (moved: Int, missed: Int) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return (0, 0) }

        // Snapshot before moving anything. Restore rearranges real windows and
        // there is no system-level undo for that; a wrong layout, or a rule
        // firing at the wrong moment, would otherwise scatter a working desk
        // with no way back. Held in memory only — it is an undo, not a saved
        // layout, and persisting it would clutter the user's list.
        captureUndoSnapshot()

        isRestoring = true
        defer { isRestoring = false }

        var windowsByBundle: [String: [AppWindow]] = [:]
        for window in WindowRegistry.shared.windows where !window.isMinimized {
            windowsByBundle[window.bundleIdentifier, default: []].append(window)
        }

        var moved = 0
        var missed = 0
        var claimed = Set<String>()

        for placement in layout.placements {
            let candidates = (windowsByBundle[placement.bundleIdentifier] ?? [])
                .filter { !claimed.contains($0.windowIdentifier) }

            guard !candidates.isEmpty else {
                missed += 1
                continue
            }

            let match = candidates.first { $0.windowTitle == placement.windowTitle } ?? candidates[0]
            claimed.insert(match.windowIdentifier)

            let target = Self.resolvedFrame(for: placement)
            let axFrame = CGRect(
                x: target.minX,
                y: primaryHeight - target.maxY,
                width: target.width,
                height: target.height
            )

            // Applied twice on purpose. AX sets position then size, and a
            // window still carrying its old size can have the move clamped by
            // whichever screen it is currently on — the size lands, the
            // position quietly does not. The second pass runs with the size
            // already correct, so the position sticks. This is the difference
            // between "restore worked" and "restore resized everything and
            // moved nothing".
            let first = WindowRegistry.shared.resize(match, to: axFrame)
            let second = WindowRegistry.shared.resize(match, to: axFrame)

            if first || second {
                moved += 1
            } else {
                missed += 1
            }
        }

        return (moved, missed)
    }

    /// Launches any app the layout needs that is not currently running.
    /// Returns how many were launched, so a caller can wait before restoring.
    @discardableResult
    func launchMissingApps(for layout: WorkspaceLayout) -> Int {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        var launched = 0

        for bundleID in layout.bundleIdentifiers where !running.contains(bundleID) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched += 1
        }

        return launched
    }

    /// The arrangement as it was immediately before the last restore.
    private(set) var undoSnapshot: WorkspaceLayout?

    private func captureUndoSnapshot() {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }

        var placements: [WindowPlacement] = []
        for window in WindowRegistry.shared.windows where !window.isMinimized {
            guard let axFrame = window.frame, axFrame.width > 0, axFrame.height > 0 else { continue }
            let nsFrame = CGRect(
                x: axFrame.minX,
                y: primaryHeight - axFrame.maxY,
                width: axFrame.width,
                height: axFrame.height
            )
            placements.append(
                WindowPlacement(
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.windowTitle,
                    frame: nsFrame,
                    displayUUID: Self.displayUUID(containing: nsFrame)
                )
            )
        }

        guard !placements.isEmpty else { return }
        undoSnapshot = WorkspaceLayout(
            id: "undo",
            name: "Before Last Restore",
            placements: placements,
            bundleIdentifiers: []
        )
    }

    /// Puts windows back where they were before the last restore.
    @discardableResult
    func undoLastRestore() -> (moved: Int, missed: Int) {
        guard let snapshot = undoSnapshot else { return (0, 0) }
        // Cleared first so undoing an undo cannot ping-pong between two
        // arrangements.
        undoSnapshot = nil
        return restore(snapshot)
    }

    func delete(_ layout: WorkspaceLayout) {
        layouts.removeAll { $0.id == layout.id }
        save()
    }

    func rename(_ layout: WorkspaceLayout, to name: String) {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layouts[index].name = name
        save()
    }

    // MARK: - Display resolution

    /// Where a placement should land today.
    ///
    /// If the display it was captured on is still attached, the stored absolute
    /// frame is already correct. If that display is gone — laptop undocked, a
    /// monitor unplugged — the window would otherwise be sent to coordinates
    /// no screen occupies, i.e. off-screen and unreachable. In that case the
    /// frame is remapped proportionally onto the main screen.
    private static func resolvedFrame(for placement: WindowPlacement) -> CGRect {
        guard let uuid = placement.displayUUID else { return placement.frame }

        let stillAttached = NSScreen.screens.contains { screen in
            screen.displayID.flatMap(displayUUIDString) == uuid
        }
        if stillAttached { return placement.frame }

        guard let fallback = NSScreen.main else { return placement.frame }
        let visible = fallback.visibleFrame

        // Clamp rather than scale: a window keeps its size and simply comes
        // back on-screen, which is less surprising than being resized because
        // a monitor was unplugged.
        let width = min(placement.frame.width, visible.width)
        let height = min(placement.frame.height, visible.height)
        return CGRect(
            x: min(max(placement.frame.minX, visible.minX), visible.maxX - width),
            y: min(max(placement.frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private static func displayUUID(containing frame: CGRect) -> String? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best?.displayID.flatMap(displayUUIDString)
    }

    private static func displayUUIDString(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([WorkspaceLayout].self, from: data) else { return }
        layouts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
