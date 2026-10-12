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

/// One attached display, reduced to what layout capture and restore need.
struct LayoutDisplay: Equatable {
    /// Persistent display UUID, nil when the system could not provide one.
    var uuid: String?
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Everything the layout service reads from or does to the running system.
/// The live value talks to NSScreen, the window registry and NSWorkspace; tests
/// substitute plain values so capture, restore and the launch-wait loop can be
/// exercised without moving a real window.
struct WorkspaceLayoutEnvironment {
    /// Attached displays, primary first (NSScreen.screens order).
    var displays: () -> [LayoutDisplay]
    /// The display NSScreen.main reports, used when a placement's own
    /// display is gone.
    var mainDisplay: () -> LayoutDisplay?
    var windows: () -> [AppWindow]
    var resize: (AppWindow, CGRect) -> Bool
    var runningBundleIdentifiers: () -> Set<String>
    /// Launches the app; false when no installed app has that identifier.
    var launchApp: (String) -> Bool
    var now: () -> Date
    var schedule: (TimeInterval, @escaping () -> Void) -> Void

    static let live = WorkspaceLayoutEnvironment(
        displays: { NSScreen.screens.map(WorkspaceLayoutEnvironment.display(for:)) },
        mainDisplay: { NSScreen.main.map(WorkspaceLayoutEnvironment.display(for:)) },
        windows: { WindowRegistry.shared.windows },
        resize: { WindowRegistry.shared.resize($0, to: $1) },
        runningBundleIdentifiers: {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        launchApp: { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        },
        now: { Date() },
        schedule: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    )

    private static func display(for screen: NSScreen) -> LayoutDisplay {
        LayoutDisplay(
            uuid: screen.displayID.flatMap(WorkspaceLayoutService.displayUUIDString),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}

@MainActor
final class WorkspaceLayoutService: ObservableObject {
    static let shared = WorkspaceLayoutService()

    @Published private(set) var layouts: [WorkspaceLayout] = []

    /// Set while a restore is running so the dock's own window-reservation
    /// logic does not fight the placement pass by shoving windows back off
    /// the dock strip mid-restore.
    @Published private(set) var isRestoring = false

    static let defaultsKey = "wharf.workspaceLayouts"
    private let defaults: UserDefaults
    private let environment: WorkspaceLayoutEnvironment

    /// `defaults` and `environment` are injectable so tests run against a
    /// throwaway suite and a fake desk instead of the real ones.
    init(defaults: UserDefaults = .standard, environment: WorkspaceLayoutEnvironment = .live) {
        self.defaults = defaults
        self.environment = environment
        load()
    }

    // MARK: - Capture

    /// Records every visible window's position, size and display.
    ///
    /// Minimized windows are skipped: they have no meaningful frame, and
    /// restoring one would need un-minimizing it, which changes what the user
    /// asked to capture.
    func capture(name: String) {
        let displays = environment.displays()
        guard let primaryHeight = displays.first?.frame.height else { return }

        var placements: [WindowPlacement] = []
        var bundles = Set<String>()

        for window in environment.windows() where !window.isMinimized {
            guard let axFrame = window.frame, axFrame.width > 0, axFrame.height > 0 else { continue }

            // AX reports a top-left origin with Y increasing downward; every
            // frame stored here is in NSScreen space so restore can compare it
            // against screens directly.
            let nsFrame = Self.flipY(axFrame, primaryHeight: primaryHeight)

            placements.append(
                WindowPlacement(
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.windowTitle,
                    frame: nsFrame,
                    displayUUID: Self.displayUUID(containing: nsFrame, in: displays)
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
    /// - Parameter capturesUndo: whether to snapshot the current arrangement
    ///   first. False when the restore IS the undo, otherwise undoing would
    ///   immediately record the state it just left and the two arrangements
    ///   would ping-pong forever.
    @discardableResult
    func restore(_ layout: WorkspaceLayout, capturesUndo: Bool = true) -> (moved: Int, missed: Int) {
        let displays = environment.displays()
        guard let primaryHeight = displays.first?.frame.height else { return (0, 0) }

        // Snapshot before moving anything. Restore rearranges real windows and
        // there is no system-level undo for that; a wrong layout, or a rule
        // firing at the wrong moment, would otherwise scatter a working desk
        // with no way back. Held in memory only — it is an undo, not a saved
        // layout, and persisting it would clutter the user's list.
        // A placement happening now supersedes anything still waiting on apps.
        pendingGeneration += 1

        if capturesUndo {
            captureUndoSnapshot()
        }

        isRestoring = true
        defer { isRestoring = false }

        let matches = Self.match(
            layout.placements,
            to: environment.windows().filter { !$0.isMinimized }
        )

        var moved = 0
        var missed = 0
        let mainDisplay = environment.mainDisplay()

        for (placement, candidate) in zip(layout.placements, matches) {
            guard let match = candidate else {
                missed += 1
                continue
            }

            let target = Self.resolvedFrame(for: placement, displays: displays, main: mainDisplay)
            let axFrame = Self.flipY(target, primaryHeight: primaryHeight)

            // Applied twice on purpose. AX sets position then size, and a
            // window still carrying its old size can have the move clamped by
            // whichever screen it is currently on — the size lands, the
            // position quietly does not. The second pass runs with the size
            // already correct, so the position sticks. This is the difference
            // between "restore worked" and "restore resized everything and
            // moved nothing".
            let first = environment.resize(match, axFrame)
            let second = environment.resize(match, axFrame)

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
    /// Launches missing apps, then restores once their windows actually exist.
    ///
    /// Replaces a fixed delay. Apps launch at wildly different speeds, and a
    /// hardcoded wait either restores before a slow app has drawn a window (so
    /// that app is silently skipped) or idles after a fast one. This polls for
    /// the windows it is waiting on and gives up at a deadline.
    func launchAndRestore(_ layout: WorkspaceLayout, timeout: TimeInterval = 15) {
        let launchedIDs = launchMissingAppsReturningIDs(for: layout)
        guard !launchedIDs.isEmpty else {
            restore(layout)
            return
        }

        // A pending placement is cancellable. Apps can take many seconds to
        // draw a window, and in that gap the user may pick a different layout
        // or turn the rule off. Without a generation token the earlier, now
        // unwanted placement still lands and scatters the desk.
        pendingGeneration += 1
        let generation = pendingGeneration

        // Only the apps actually launched are waited on. Waiting on every app
        // in the layout stalls the full timeout whenever a captured app is
        // running with all its windows closed.
        let expected = launchedIDs
        let deadline = environment.now().addingTimeInterval(timeout)

        func attempt() {
            guard generation == pendingGeneration else { return }

            let present = Set(
                environment.windows()
                    .filter { !$0.isMinimized }
                    .map(\.bundleIdentifier)
            )

            if expected.subtracting(present).isEmpty || environment.now() >= deadline {
                restore(layout)
                return
            }
            environment.schedule(0.5, attempt)
        }

        environment.schedule(0.5, attempt)
    }

    /// Cancels any placement that is waiting on apps to finish launching.
    func cancelPendingRestore() {
        pendingGeneration += 1
    }

    private func launchMissingAppsReturningIDs(for layout: WorkspaceLayout) -> Set<String> {
        let running = environment.runningBundleIdentifiers()
        var launched: Set<String> = []

        for bundleID in layout.bundleIdentifiers where !running.contains(bundleID) {
            guard environment.launchApp(bundleID) else { continue }
            launched.insert(bundleID)
        }

        return launched
    }

    @discardableResult
    func launchMissingApps(for layout: WorkspaceLayout) -> Int {
        let running = environment.runningBundleIdentifiers()
        var launched = 0

        for bundleID in layout.bundleIdentifiers where !running.contains(bundleID) {
            guard environment.launchApp(bundleID) else { continue }
            launched += 1
        }

        return launched
    }

    /// The arrangement as it was immediately before the last restore.
    private(set) var undoSnapshot: WorkspaceLayout?

    /// Bumped whenever a new placement starts or one is cancelled, so a
    /// still-waiting poll from an older request quietly gives up.
    private var pendingGeneration = 0

    private func captureUndoSnapshot() {
        let displays = environment.displays()
        guard let primaryHeight = displays.first?.frame.height else { return }

        var placements: [WindowPlacement] = []
        for window in environment.windows() where !window.isMinimized {
            guard let axFrame = window.frame, axFrame.width > 0, axFrame.height > 0 else { continue }
            let nsFrame = Self.flipY(axFrame, primaryHeight: primaryHeight)
            placements.append(
                WindowPlacement(
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.windowTitle,
                    frame: nsFrame,
                    displayUUID: Self.displayUUID(containing: nsFrame, in: displays)
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
        return restore(snapshot, capturesUndo: false)
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
    static func resolvedFrame(
        for placement: WindowPlacement,
        displays: [LayoutDisplay],
        main: LayoutDisplay?
    ) -> CGRect {
        guard let uuid = placement.displayUUID else { return placement.frame }

        if let attached = displays.first(where: { $0.uuid == uuid }) {
            // Attached is not the same as unmoved. Rearranging displays in
            // System Settings changes their global origins, so a frame captured
            // when this monitor sat to the left replays off-screen once it sits
            // to the right. Clamp it back inside the screen it belongs to.
            let visible = attached.visibleFrame
            if visible.contains(placement.frame) { return placement.frame }
            return clamp(placement.frame, into: visible)
        }

        guard let fallback = main else { return placement.frame }

        // Clamp rather than scale: a window keeps its size and simply comes
        // back on-screen, which is less surprising than being resized because
        // a monitor was unplugged.
        return clamp(placement.frame, into: fallback.visibleFrame)
    }

    /// Keeps the frame's size (shrunk only when larger than `visible`) and
    /// slides it fully inside `visible`.
    static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    /// AX space (top-left origin, Y down) and NSScreen space (bottom-left
    /// origin, Y up) are related by the same flip in both directions.
    static func flipY(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Picks, for each placement in order, the window it should move, or nil
    /// when the app has no unclaimed window left. Matching is per app: the
    /// first unclaimed window whose title equals the placement's, otherwise
    /// the first unclaimed window of that app.
    static func match(_ placements: [WindowPlacement], to windows: [AppWindow]) -> [AppWindow?] {
        var windowsByBundle: [String: [AppWindow]] = [:]
        for window in windows {
            windowsByBundle[window.bundleIdentifier, default: []].append(window)
        }

        var claimed = Set<String>()
        var result: [AppWindow?] = []

        for placement in placements {
            let candidates = (windowsByBundle[placement.bundleIdentifier] ?? [])
                .filter { !claimed.contains($0.windowIdentifier) }

            guard !candidates.isEmpty else {
                result.append(nil)
                continue
            }

            let match = candidates.first { $0.windowTitle == placement.windowTitle } ?? candidates[0]
            claimed.insert(match.windowIdentifier)
            result.append(match)
        }

        return result
    }

    static func displayUUID(containing frame: CGRect, in displays: [LayoutDisplay]) -> String? {
        var best: LayoutDisplay?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = display.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best?.uuid
    }

    static func displayUUIDString(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([WorkspaceLayout].self, from: data) else { return }
        layouts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
