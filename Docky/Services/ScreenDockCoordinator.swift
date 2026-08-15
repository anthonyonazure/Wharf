//
//  ScreenDockCoordinator.swift
//  Wharf
//
//  Owns the set of dock windows and keeps it in sync with the connected
//  displays. Docky assumed a single dock; Wharf's reason to exist is one dock
//  per screen, all visible at once.
//

import AppKit

extension NSScreen {
    /// The stable hardware identifier for this screen.
    ///
    /// `NSScreen` instances are replaced wholesale on every display
    /// reconfiguration, so they can't be used as dictionary keys or held
    /// across a monitor sleeping. `CGDirectDisplayID` survives.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Creates, retains and tears down dock windows so that exactly the right set
/// exists for the current preference and the currently attached displays.
///
/// Two shapes, chosen by `DockyPreferences.windowDisplayTarget`:
///
/// - single-window modes (`.primaryDisplay`, `.displayContainingPointer`):
///   one unbound window, exactly as upstream Docky behaves.
/// - `.allDisplays`: one window per screen, each bound to its display ID and
///   pinned there.
final class ScreenDockCoordinator {
    static let shared = ScreenDockCoordinator()

    /// Keyed by display ID so entries survive `NSScreen` objects being
    /// rebuilt. The unbound single-window controller is held separately
    /// because it has no display of its own.
    private var boundControllers: [CGDirectDisplayID: MainWindowController] = [:]
    private var unboundController: MainWindowController?
    private var isStarted = false
    private var isRebuilding = false

    private init() {}

    /// Builds the initial dock set and begins watching for display and
    /// preference changes. Safe to call more than once.
    func start() {
        guard !isStarted else {
            rebuild()
            return
        }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observeDisplayTargetPreference()
        rebuild()
    }

    /// Every dock window currently on screen.
    var allDockWindows: [MainWindow] {
        let bound = boundControllers.values.compactMap { $0.window as? MainWindow }
        let unbound = (unboundController?.window as? MainWindow).map { [$0] } ?? []
        return bound + unbound
    }

    /// The dock window belonging to a given screen, when one exists. Falls
    /// back to the unbound window so single-window modes still answer.
    func dockWindow(for screen: NSScreen) -> MainWindow? {
        if let displayID = screen.displayID,
           let controller = boundControllers[displayID],
           let window = controller.window as? MainWindow {
            return window
        }
        return unboundController?.window as? MainWindow
    }

    // MARK: - Reacting to change

    @objc private func screenParametersDidChange() {
        // Display reconfiguration arrives before AppKit has settled the new
        // screen frames; coalesce to the next runloop pass so windows are
        // positioned against final geometry rather than transient values.
        DispatchQueue.main.async { [weak self] in
            self?.rebuild()
        }
    }

    /// Bridges the `@Observable` preference store into AppKit land, matching
    /// the withObservationTracking/re-register pattern used elsewhere in the
    /// project. Re-registers itself after each change.
    private func observeDisplayTargetPreference() {
        withObservationTracking {
            _ = DockyPreferences.shared.windowDisplayTarget
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuild()
                self.observeDisplayTargetPreference()
            }
        }
    }

    // MARK: - Reconciliation

    /// Brings the live window set in line with what the current mode and the
    /// attached displays call for. Written as a reconcile rather than a
    /// teardown-and-recreate so that untouched screens keep their existing
    /// window, and with it their tiles, overlays and animation state.
    private func rebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        if DockyPreferences.shared.windowDisplayTarget.usesSingleWindow {
            reconcileSingleWindow()
        } else {
            reconcileOnePerDisplay()
        }
    }

    private func reconcileSingleWindow() {
        // Drop any per-display windows left over from `.allDisplays`.
        for (_, controller) in boundControllers {
            close(controller)
        }
        boundControllers.removeAll()

        guard unboundController == nil else { return }
        guard let controller = makeController(assignedDisplayID: nil) else { return }
        unboundController = controller
        controller.showWindow(self)
    }

    private func reconcileOnePerDisplay() {
        // Retire the shared window; in this mode every dock is display-bound.
        if let unboundController {
            close(unboundController)
            self.unboundController = nil
        }

        let attached = NSScreen.screens.compactMap(\.displayID)
        let attachedSet = Set(attached)

        // Remove docks whose display went away (unplugged, or asleep).
        for (displayID, controller) in boundControllers where !attachedSet.contains(displayID) {
            close(controller)
            boundControllers.removeValue(forKey: displayID)
        }

        // Add docks for displays that don't have one yet.
        for displayID in attached where boundControllers[displayID] == nil {
            guard let controller = makeController(assignedDisplayID: displayID) else { continue }
            boundControllers[displayID] = controller
            controller.showWindow(self)
        }

        // Displays that kept their dock may still have moved or been resized;
        // nudge every survivor to re-resolve its frame.
        for controller in boundControllers.values {
            (controller.window as? MainWindow)?.reapplyFrameForDisplayChange()
        }
    }

    // MARK: - Window construction

    /// Loads a fresh MainWindow from the nib. Each call yields an independent
    /// window with its own overlay controllers, so docks on different screens
    /// don't share editor, launchpad or switcher state.
    private func makeController(assignedDisplayID: CGDirectDisplayID?) -> MainWindowController? {
        var topLevelObjects: NSArray?
        let didLoadNib = Bundle.main.loadNibNamed(
            "MainWindow",
            owner: nil,
            topLevelObjects: &topLevelObjects
        )

        guard
            didLoadNib,
            let mainWindow = (topLevelObjects as? [Any])?.first(where: { $0 is MainWindow }) as? MainWindow
        else {
            assertionFailure("Failed to load MainWindow.xib")
            return nil
        }

        // Bind before the controller is built: overlay controllers read the
        // window's target screen during construction.
        mainWindow.assignedDisplayID = assignedDisplayID

        return MainWindowController(window: mainWindow)
    }

    private func close(_ controller: MainWindowController) {
        (controller.window as? MainWindow)?.prepareForCoordinatorTeardown()
        controller.close()
    }
}
