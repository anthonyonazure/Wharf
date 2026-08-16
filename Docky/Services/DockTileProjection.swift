//
//  DockTileProjection.swift
//  Wharf
//
//  Turns the one shared tile list into what a particular dock should show.
//
//  `TileStore` stays process-wide on purpose: pinned apps, widgets and folders
//  are the same on every display, which is what mirror mode means. What differs
//  per dock is which running windows belong to that screen, and whether the
//  dock is showing one tile per app or one card per window.
//
//  Written as a pure transform over the store's output rather than as another
//  stateful service, so three docks projecting the same list cannot disagree.
//

import AppKit

enum DockTileProjection {
    /// Produce the tile list for one dock.
    ///
    /// - Parameters:
    ///   - tiles: the shared list from `TileStore`.
    ///   - dock: which dock is asking (carries its display).
    ///   - windows: every known window, from `WindowRegistry`.
    static func project(
        _ tiles: [Tile],
        dock: DockContext,
        windows: [AppWindow]
    ) -> [Tile] {
        let preferences = DockyPreferences.shared
        let mode = preferences.dockContentMode
        let filtersToScreen = preferences.showsOnlyCurrentScreenWindows

        // Nothing to do in the default configuration; skip the work entirely
        // so the common path stays as cheap as upstream's.
        guard mode == .taskbar || filtersToScreen else { return tiles }

        let screen = dock.screen
        let windowsForThisDock = filtersToScreen
            ? windows.filter { isWindow($0, on: screen) }
            : windows

        var windowsByBundle: [String: [AppWindow]] = [:]
        for window in windowsForThisDock where !window.isMinimized {
            windowsByBundle[window.bundleIdentifier, default: []].append(window)
        }

        // Minimized-window cards name a specific window, so per-screen
        // filtering has to judge them individually. Passing them through
        // untouched put every display's minimized windows on every dock.
        let visibleWindowIDs = Set(windowsForThisDock.map(\.windowIdentifier))

        var result: [Tile] = []
        for tile in tiles {
            if case let .minimizedWindow(window) = tile.content {
                if !filtersToScreen || visibleWindowIDs.contains(window.windowIdentifier) {
                    result.append(tile)
                }
                continue
            }

            guard case let .app(appTile) = tile.content else {
                result.append(tile)
                continue
            }

            let appWindows = windowsByBundle[appTile.bundleIdentifier] ?? []

            // Per-screen filtering hides a running app that has nothing on this
            // screen. Pinned apps are launchers, not window indicators, so they
            // stay put — otherwise the dock would rearrange itself every time a
            // window moved between monitors.
            if filtersToScreen, appWindows.isEmpty, !isPinned(tile) {
                continue
            }

            guard mode == .taskbar else {
                result.append(tile)
                continue
            }

            result.append(contentsOf: expand(appTile: appTile, tile: tile, windows: appWindows))
        }

        return result
    }

    /// One card per window, one icon per app, or a mix, per the grouping rule.
    private static func expand(appTile: AppTile, tile: Tile, windows: [AppWindow]) -> [Tile] {
        guard !windows.isEmpty else { return [tile] }

        switch DockyPreferences.shared.windowGrouping {
        case .always:
            // Classic Dock behavior: the app is one tile no matter how many
            // windows it has.
            return [tile]
        case .never:
            return windows.map(windowTile)
        case .automatic:
            // Tungsten Edge's rule, and the reason a per-window taskbar stays
            // readable on a Mac: a single-window app is indistinguishable from
            // its icon, so only apps with several windows earn several cards.
            return windows.count > 1 ? windows.map(windowTile) : [tile]
        }
    }

    /// Matches the id scheme `TileStore` already uses for window tiles, so a
    /// card keeps its identity (and its animations) as windows come and go.
    private static func windowTile(_ window: AppWindow) -> Tile {
        Tile(id: "minimized-window:\(window.windowIdentifier)", content: .minimizedWindow(window))
    }

    private static func isPinned(_ tile: Tile) -> Bool {
        tile.id.hasPrefix("pinned:")
    }

    /// Whether a window sits on a given screen.
    ///
    /// `AppWindow.frame` comes from the accessibility API, whose origin is the
    /// top-left of the primary display with Y increasing downward. `NSScreen`
    /// uses a bottom-left origin with Y increasing upward, so the frame has to
    /// be flipped before any comparison. Comparing them directly appears to
    /// work on a single display and silently misplaces every window once a
    /// second monitor is attached above or below.
    static func isWindow(_ window: AppWindow, on screen: NSScreen?) -> Bool {
        guard let screen,
              let axFrame = window.frame,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return false }

        let flipped = CGRect(
            x: axFrame.origin.x,
            y: primaryHeight - axFrame.origin.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )

        // Largest-overlap wins, so a window straddling two monitors counts as
        // being on the one showing most of it rather than on both.
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let intersection = candidate.frame.intersection(flipped)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = candidate
            }
        }

        return bestScreen == screen
    }
}
