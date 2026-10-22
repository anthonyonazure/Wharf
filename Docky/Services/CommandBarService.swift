//
//  CommandBarService.swift
//  Wharf
//
//  The Command Bar: a floating search field summoned by a global shortcut
//  that finds apps, open windows, files, menu commands of the app in front
//  and window snap layouts, and answers arithmetic and unit conversions.
//
//  Modeled on Vorssaint's command bar (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later). The pure parts (calculator, units, ranking) live in
//  CommandBarCore.swift; this file gathers candidates, runs the choice, and
//  owns the hot key. CommandBarWindowController shows it.
//

import AppKit
import Carbon
import Combine

/// One row in the bar. `actions[0]` is what Return does; Tab lists the rest.
struct CommandBarResult: Identifiable {
    enum Kind {
        case calculation, conversion, app, window, file, menu, snap

        var label: String {
            switch self {
            case .calculation: "Calculator"
            case .conversion: "Conversion"
            case .app: "App"
            case .window: "Window"
            case .file: "File"
            case .menu: "Menu"
            case .snap: "Snap"
            }
        }
    }

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let symbolName: String
        /// Loses work or ends something: needs a second Return or click.
        var isDestructive = false
        /// Runs on the main queue after the bar closes. False means nothing
        /// happened, so no history is recorded.
        let perform: () -> Bool
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: NSImage?
    let symbolName: String?
    /// Shown at the trailing edge, such as a menu item's own shortcut.
    let accessory: String?
    /// Recency key; nil for results that are not worth remembering.
    let recencyKey: String?
    let actions: [Action]
    /// A cheap check on the main queue, with no Accessibility calls, run
    /// before any action. Returns why the row can no longer run.
    var precheck: (() -> String?)? = nil
    /// Menu rows are revalidated and pressed off the main queue instead of
    /// through `actions[0].perform`.
    var menuItem: CommandBarMenuItem? = nil

    var isDestructive: Bool { actions.first?.isDestructive ?? false }
    /// Rows that may be selected without the user choosing them.
    var isDefaultable: Bool { !actions.isEmpty && !isDestructive }
}

/// A destructive action waiting for its second Return.
struct CommandBarConfirmation: Equatable {
    let resultID: String
    let actionIndex: Int
    let message: String
}

final class CommandBarService: ObservableObject {
    static let shared = CommandBarService()

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet {
            // Bounded at entry, before any trimming or folding.
            let clamped = CommandBarQueryLimit.clamp(query)
            if clamped != query { query = clamped }
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    @Published private(set) var results: [CommandBarResult] = []
    /// Derived from `selectedID`; nil when nothing is safe to preselect.
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var showsActions = false
    @Published var actionIndex = 0
    @Published private(set) var pendingConfirmation: CommandBarConfirmation?
    /// Why the last choice did not run, shown in the bar.
    @Published private(set) var statusMessage: String?
    /// True when the shortcut could not be registered, almost always because
    /// another app (Raycast, Alfred) holds it. Shown in the settings pane.
    @Published private(set) var isShortcutUnavailable = false
    /// Set when another Wharf setting changed after the shortcut was
    /// recorded and now collides with it; the hot key stays off meanwhile.
    @Published private(set) var activeConflictMessage: String?

    /// True while the settings pane records a shortcut, so pressing the
    /// current one does not open the bar.
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            registerHotKey()
        }
    }

    private let preferences = CommandBarPreferences.shared
    private var cancellables: Set<AnyCancellable> = []
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    /// 'CMDB', distinct from the Launchpad, Start Menu, switcher and snap signatures.
    nonisolated static let hotKeySignature = OSType(0x434D4442)

    // Captured when the bar opens, so the target stays the app the user was in.
    private var targetApp: NSRunningApplication?
    private var targetWindow: AppWindow?
    private var appCandidates: [AppCandidate] = []
    private var menuItems: [CommandBarMenuItem] = []
    private var menuWalk: CommandBarMenuWalk?
    /// Identity of the selected row; survives results that arrive later.
    private var selectedID: String?
    /// Spotlight hits and the exact query they answer. Rows are only built
    /// while that query is still the one in the field.
    private var fileResults: [URL] = []
    private var fileResultsQuery: String?
    private var fileQuery: NSMetadataQuery?
    private var fileQueryObservers: [NSObjectProtocol] = []
    private var fileDebounce: DispatchWorkItem?
    private var fileDeadline: DispatchWorkItem?
    private var homeIsLocal = false
    private var isRunning = false
    private var generation = 0

    private struct AppCandidate {
        let bundleIdentifier: String
        let name: String
        let running: NSRunningApplication?
    }

    private init() {}

    func start() {
        installHotKeyHandlerIfNeeded()
        // Every setting `conflictMessage` reads is read here too, so turning
        // on Windows Keyboard Mode or taking the combination for another
        // shortcut re-checks the bar's own shortcut.
        observeChanges { [weak self] in
            _ = CommandBarPreferences.shared.enabled
            _ = CommandBarPreferences.shared.shortcut
            let wharf = DockyPreferences.shared
            _ = wharf.windowsKeyboardMode
            _ = wharf.windowsKeyboardSnipShortcut
            _ = wharf.launchpadShortcut
            _ = wharf.windowSwitcherShortcut
            for action in WindowSnapAction.allCases {
                _ = wharf.windowSnapShortcut(for: action)
            }
            self?.registerHotKey()
        }
        .store(in: &cancellables)
    }

    /// The process the bar acts on, for the window controller.
    var targetProcessIdentifier: pid_t? { targetApp?.processIdentifier }

    // MARK: - Presentation

    func toggle() {
        isPresented ? dismiss() : present()
    }

    func present() {
        guard preferences.enabled else { return }
        generation += 1
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        targetWindow = nil
        appCandidates = preferences.isOn(.apps) ? Self.collectApps() : []
        menuItems = []
        fileResults = []
        fileResultsQuery = nil
        homeIsLocal = (try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
        selectedID = nil
        showsActions = false
        actionIndex = 0
        pendingConfirmation = nil
        statusMessage = nil
        isRunning = false
        query = ""
        recompute()
        isPresented = true
        resolveTargetWindow()
        loadMenus()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        generation += 1
        stopFileQuery()
        fileDebounce?.cancel()
        menuWalk?.cancel()
        menuWalk = nil
        menuItems = []
        appCandidates = []
        fileResults = []
        fileResultsQuery = nil
        targetWindow = nil
        selectedID = nil
        showsActions = false
        pendingConfirmation = nil
        statusMessage = nil
    }

    /// Another app came to the front while the bar was open: whatever the
    /// bar captured no longer describes where a command would land.
    func applicationDidActivate(_ app: NSRunningApplication?) {
        guard isPresented, let app,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.processIdentifier != targetApp?.processIdentifier else { return }
        dismiss()
    }

    // MARK: - Keyboard

    func moveSelection(by delta: Int) {
        pendingConfirmation = nil
        statusMessage = nil
        if showsActions {
            let count = selectedResult?.actions.count ?? 0
            guard count > 0 else { return }
            actionIndex = (actionIndex + delta + count) % count
        } else {
            guard !results.isEmpty else { return }
            let current = selectedIndex ?? (delta > 0 ? -1 : results.count)
            select(min(max(current + delta, 0), results.count - 1))
        }
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedID = results[index].id
        selectedIndex = index
    }

    /// Tab: open or close the quick-action list of the selected row.
    func toggleActions() {
        guard let result = selectedResult, result.actions.count > 1 || showsActions else { return }
        pendingConfirmation = nil
        showsActions.toggle()
        actionIndex = 0
    }

    /// Escape drops a pending confirmation first, then the action list,
    /// then the bar.
    func cancel() {
        if pendingConfirmation != nil {
            pendingConfirmation = nil
        } else if showsActions {
            showsActions = false
        } else {
            dismiss()
        }
    }

    func runSelected() {
        guard let result = selectedResult else { return }
        let index = showsActions ? actionIndex : 0
        run(result, actionAt: index)
    }

    /// Return and clicks both land here. A destructive action only runs on
    /// the second request for the same row and action. Anything cached is
    /// checked again first, and history is only recorded once it worked.
    func run(_ result: CommandBarResult, actionAt index: Int = 0) {
        guard isPresented, !isRunning,
              let position = results.firstIndex(where: { $0.id == result.id }),
              result.actions.indices.contains(index) else { return }
        if selectedID != result.id {
            select(position)
            showsActions = false
        }
        let action = result.actions[index]
        statusMessage = nil

        if action.isDestructive {
            let message = result.kind == .menu
                ? "Press Return again to run \(result.title) in \(targetApp?.localizedName ?? "the app")."
                : "Press Return again to \(action.title.lowercased()) \(result.title)."
            let confirmation = CommandBarConfirmation(resultID: result.id, actionIndex: index, message: message)
            guard pendingConfirmation == confirmation else {
                pendingConfirmation = confirmation
                return
            }
        }
        pendingConfirmation = nil

        if let failure = result.precheck?() {
            statusMessage = failure
            return
        }
        if let item = result.menuItem, index == 0 {
            runMenuCommand(item)
            return
        }

        let key = result.recencyKey
        dismiss()
        // Let the panel go first, so a snap lands on the app the user was in,
        // not on the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if action.perform() {
                if let key { CommandBarPreferences.shared.recordUse(key) }
            } else {
                NSSound.beep()
            }
        }
    }

    /// Checks the frontmost app on the main queue, then the menu item itself
    /// off the main queue with a short timeout, with the bar still open so a
    /// failure can be shown there. Only then closes the bar and presses.
    private func runMenuCommand(_ item: CommandBarMenuItem) {
        let appName = targetApp?.localizedName ?? "The app"
        guard let pid = targetApp?.processIdentifier, item.pid == pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            statusMessage = "\(appName) is no longer in front, so its menu command did not run."
            return
        }
        isRunning = true
        let expected = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = CommandBarMenus.revalidate(item)
            DispatchQueue.main.async {
                let service = CommandBarService.shared
                service.isRunning = false
                guard service.isPresented, service.generation == expected else { return }
                if let failure {
                    service.statusMessage = failure + " Nothing was run."
                    return
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    service.statusMessage = "\(appName) is no longer in front, so its menu command did not run."
                    return
                }
                service.dismiss()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                    // Menu commands record no history: their titles can name documents.
                    if !CommandBarMenus.press(item) {
                        DispatchQueue.main.async { NSSound.beep() }
                    }
                }
            }
        }
    }

    var selectedResult: CommandBarResult? {
        guard let selectedIndex, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    // MARK: - Results

    private func queryDidChange() {
        showsActions = false
        pendingConfirmation = nil
        statusMessage = nil
        selectedID = nil
        // Hits for the previous text must never be openable under the new one.
        fileResults = []
        fileResultsQuery = nil
        recompute()
        scheduleFileSearch()
    }

    private func recompute() {
        // Normalized once here; the ranking prepares its query once per call.
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = preferences.maxResults
        var rows: [CommandBarResult] = []

        if preferences.isOn(.calculator) {
            switch CommandBarCalculator.evaluation(of: text) {
            case .result(let calc): rows.append(calculationRow(calc, expression: text))
            case .ambiguous: rows.append(ambiguousRow(id: "calc", kind: .calculation, input: text))
            case nil: break
            }
        }
        if preferences.isOn(.units) {
            switch CommandBarUnits.conversion(of: text) {
            case .result(let conversion): rows.append(conversionRow(conversion, input: text))
            case .ambiguous: rows.append(ambiguousRow(id: "units", kind: .conversion, input: text))
            case nil: break
            }
        }

        let local = rankedLocalRows(query: text, limit: limit)
        let files = text.count >= 2 && fileResultsQuery == text ? fileResults.map { fileRow($0, query: text) } : []
        // Files keep a few rows for themselves; local rows fill the rest.
        let fileShare = files.isEmpty ? 0 : min(files.count, max(2, limit / 3))
        rows += local.prefix(max(0, limit - rows.count - fileShare))
        rows += files.prefix(max(0, limit - rows.count))

        results = Array(rows.prefix(limit))
        // Selection follows the row's identity, so results arriving later
        // (menus, files) never slide another action under the user's finger.
        let resolved = CommandBarSelection.resolve(
            previousID: selectedID,
            rows: results.map { CommandBarSelection.Row(id: $0.id, isDefaultable: $0.isDefaultable) }
        )
        if resolved != selectedID { showsActions = false }
        // A pending confirmation only survives while its own row is still
        // the selected one.
        if pendingConfirmation?.resultID != resolved { pendingConfirmation = nil }
        selectedID = resolved
        selectedIndex = resolved.flatMap { id in results.firstIndex { $0.id == id } }
    }

    /// What is ranked: cheap to build for every app and window. Rows (with
    /// their icons and actions) are only built for the winners.
    private enum Candidate {
        case app(AppCandidate)
        case window(AppWindow)
        case menu(CommandBarMenuItem, index: Int)
        case snap(WindowSnapAction)
    }

    /// Apps, windows, menu commands and snap layouts, ranked together.
    private func rankedLocalRows(query: String, limit: Int) -> [CommandBarResult] {
        var candidates: [Candidate] = appCandidates.map { .app($0) }
        if preferences.isOn(.windows) {
            candidates += WindowRegistry.shared.windows
                .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .map { .window($0) }
        }
        if preferences.isOn(.menus) {
            candidates += menuItems.enumerated().map { .menu($1, index: $0) }
        }
        if preferences.isOn(.snap) {
            candidates += WindowSnapAction.allCases.map { .snap($0) }
        }

        let winners = CommandBarRanking.rank(
            candidates,
            query: query,
            limit: limit,
            recency: preferences.recency,
            now: Date(),
            title: { candidate in
                switch candidate {
                case .app(let app): app.name
                case .window(let window): window.windowTitle.isEmpty ? window.appDisplayName : window.windowTitle
                case .menu(let item, _): item.title
                case .snap(let action): action.title
                }
            },
            keywords: { candidate in
                switch candidate {
                case .app: []
                case .window(let window): [window.appDisplayName]
                case .menu(let item, _): [item.path.joined(separator: " ")]
                case .snap(let action): ["snap", "window", action.group.title]
                }
            },
            key: { candidate in
                switch candidate {
                case .app(let app): "app:\(app.bundleIdentifier)"
                case .window(let window): "window:\(window.id.stableString)"
                // Menu commands are never remembered, so they share one key
                // with no history behind it.
                case .menu: "menu"
                case .snap(let action): "snap:\(action.rawValue)"
                }
            },
            // Small tie breakers so an app outranks a menu item of the same name.
            weight: { candidate in
                switch candidate {
                case .app: 30
                case .window: 20
                case .menu: 10
                case .snap: 0
                }
            }
        )
        return winners.map { candidate in
            switch candidate {
            case .app(let app): appRow(app)
            case .window(let window): windowRow(window)
            case .menu(let item, let index): menuRow(item, index: index)
            case .snap(let action): snapRow(action)
            }
        }
    }

    private func calculationRow(_ calc: CommandBarCalculator.Result, expression: String) -> CommandBarResult {
        let plain = CommandBarNumberFormat.plain(calc.value)
        return CommandBarResult(
            id: "calc",
            kind: .calculation,
            title: "= \(calc.formatted)",
            subtitle: expression,
            icon: nil,
            symbolName: "plus.forwardslash.minus",
            accessory: nil,
            recencyKey: nil,
            actions: [
                .init(title: "Copy Result", symbolName: "doc.on.doc") { Self.copy(calc.formatted) },
                .init(title: "Copy Plain Number", symbolName: "number") { Self.copy(plain) },
            ]
        )
    }

    /// Shown instead of a guess when a number could be read two ways in this
    /// locale. It has no action, so it is never preselected and Return does
    /// nothing on it.
    private func ambiguousRow(id: String, kind: CommandBarResult.Kind, input: String) -> CommandBarResult {
        CommandBarResult(
            id: id,
            kind: kind,
            title: "Ambiguous number",
            subtitle: "\(input): write the number without a thousands separator, such as 1234 or 1.5",
            icon: nil,
            symbolName: "exclamationmark.triangle",
            accessory: nil,
            recencyKey: nil,
            actions: []
        )
    }

    private func conversionRow(_ conversion: CommandBarUnits.Result, input: String) -> CommandBarResult {
        let plain = CommandBarNumberFormat.plain(conversion.value)
        return CommandBarResult(
            id: "units",
            kind: .conversion,
            title: "= \(conversion.formatted)",
            subtitle: input,
            icon: nil,
            symbolName: "ruler",
            accessory: nil,
            recencyKey: nil,
            actions: [
                .init(title: "Copy Result", symbolName: "doc.on.doc") { Self.copy(conversion.formatted) },
                .init(title: "Copy Number Only", symbolName: "number") { Self.copy(plain) },
            ]
        )
    }

    private func appRow(_ app: AppCandidate) -> CommandBarResult {
        let bundleID = app.bundleIdentifier
        let running = app.running
        var actions: [CommandBarResult.Action] = [
            .init(title: running == nil ? "Open" : "Switch To", symbolName: "arrow.up.forward.app") {
                Self.openApp(bundleIdentifier: bundleID, running: running)
            },
            .init(title: "Show in Finder", symbolName: "folder") {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return true
            },
        ]
        if let running {
            actions.append(.init(title: "Hide", symbolName: "eye.slash") { running.hide() })
            actions.append(.init(title: "Quit", symbolName: "xmark.circle", isDestructive: true) { running.terminate() })
        }
        return CommandBarResult(
            id: "app:\(bundleID)",
            kind: .app,
            title: app.name,
            subtitle: running == nil ? "Application" : "Application, running",
            icon: IconCacheService.shared.icon(forBundleIdentifier: bundleID),
            symbolName: nil,
            accessory: nil,
            recencyKey: "app:\(bundleID)",
            actions: actions
        )
    }

    private func windowRow(_ window: AppWindow) -> CommandBarResult {
        let title = window.windowTitle.isEmpty ? window.appDisplayName : window.windowTitle
        let snap: (WindowSnapAction) -> CommandBarResult.Action = { action in
            .init(title: action.title, symbolName: action.symbolName) {
                let snapped = WindowSnapService.shared.perform(action, on: window)
                _ = WindowRegistry.shared.focus(window)
                return snapped
            }
        }
        return CommandBarResult(
            id: "window:\(window.id.stableString)",
            kind: .window,
            title: title,
            subtitle: window.appDisplayName + (window.isMinimized ? ", minimized" : ""),
            icon: IconCacheService.shared.icon(forBundleIdentifier: window.bundleIdentifier),
            symbolName: nil,
            accessory: nil,
            recencyKey: nil,
            actions: [
                .init(title: "Bring to Front", symbolName: "macwindow") { WindowRegistry.shared.focus(window) },
                .init(title: "Minimize", symbolName: "minus.circle") { WindowRegistry.shared.minimize(window) },
                .init(title: "Close", symbolName: "xmark.circle", isDestructive: true) { WindowRegistry.shared.close(window) },
                snap(.leftHalf),
                snap(.rightHalf),
                snap(.maximize),
            ],
            precheck: { Self.windowProblem(window) }
        )
    }

    private func menuRow(_ item: CommandBarMenuItem, index: Int) -> CommandBarResult {
        let appName = targetApp?.localizedName ?? "App"
        let path = item.path.joined(separator: " > ")
        return CommandBarResult(
            // Two items can share a path and title, so the index keeps rows unique.
            id: "menu:\(index):\(path) > \(item.title)",
            kind: .menu,
            title: item.title,
            subtitle: "\(appName): \(path)",
            icon: nil,
            symbolName: item.isDestructive ? "exclamationmark.triangle" : "filemenu.and.selection",
            accessory: item.shortcut,
            // Never remembered: Open Recent and similar menus carry document names.
            recencyKey: nil,
            actions: [
                // Pressed by runMenuCommand, off the main queue, after a recheck.
                .init(title: "Run Command", symbolName: "return", isDestructive: item.isDestructive) { false },
            ],
            menuItem: item
        )
    }

    private func snapRow(_ action: WindowSnapAction) -> CommandBarResult {
        let window = targetWindow
        let owner = window.map { $0.windowTitle.isEmpty ? $0.appDisplayName : $0.windowTitle }
        return CommandBarResult(
            id: "snap:\(action.rawValue)",
            kind: .snap,
            title: action.title,
            subtitle: owner.map { "Snap \($0)" } ?? "Snap the window in front",
            icon: nil,
            symbolName: action.symbolName,
            accessory: nil,
            recencyKey: "snap:\(action.rawValue)",
            actions: [
                .init(title: "Snap Window", symbolName: action.symbolName) {
                    guard let window else { return false }
                    return WindowSnapService.shared.perform(action, on: window)
                },
            ],
            precheck: {
                guard let window else { return "There is no window in front to snap." }
                return Self.windowProblem(window)
            }
        )
    }

    /// Whether a cached window can still be acted on, without any
    /// Accessibility call: its app is still running under the same bundle
    /// identifier, and its window number still exists and belongs to that
    /// process (window numbers are reused once a window closes).
    private static func windowProblem(_ window: AppWindow) -> String? {
        let name = window.windowTitle.isEmpty ? window.appDisplayName : window.windowTitle
        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier), !app.isTerminated,
              app.bundleIdentifier == window.bundleIdentifier else {
            return "\(window.appDisplayName) is no longer running."
        }
        if let cgWindowID = window.cgWindowID {
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], cgWindowID) as? [[String: Any]]
            guard let owner = info?.first?[kCGWindowOwnerPID as String] as? Int,
                  owner == Int(window.processIdentifier) else {
                return "\(name) is closed."
            }
        } else if !WindowRegistry.shared.windows.contains(where: { CFEqual($0.element, window.element) }) {
            return "\(name) is closed."
        }
        return nil
    }

    private func fileRow(_ url: URL, query: String) -> CommandBarResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = url.deletingLastPathComponent().path
        if folder.hasPrefix(home) { folder = "~" + folder.dropFirst(home.count) }
        return CommandBarResult(
            // Tagged with its query, so selection can never carry a file
            // from one search over to the next.
            id: "file:\(query):\(url.path)",
            kind: .file,
            title: url.lastPathComponent,
            subtitle: folder,
            icon: NSWorkspace.shared.icon(forFile: url.path),
            symbolName: nil,
            accessory: nil,
            recencyKey: nil,
            actions: [
                .init(title: "Open", symbolName: "arrow.up.forward.square") { NSWorkspace.shared.open(url) },
                .init(title: "Show in Finder", symbolName: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return true
                },
                .init(title: "Copy Path", symbolName: "doc.on.clipboard") { Self.copy(url.path) },
            ]
        )
    }

    // MARK: - Sources

    /// Installed apps from Launchpad's scan merged with every running app,
    /// keyed by bundle identifier.
    private static func collectApps() -> [AppCandidate] {
        var byID: [String: AppCandidate] = [:]
        for entry in LaunchpadOverlayService.shared.entries {
            let apps: [AppTile]
            switch entry {
            case .app(let app): apps = [app]
            case .folder(let folder): apps = folder.apps
            }
            for app in apps where byID[app.bundleIdentifier] == nil {
                byID[app.bundleIdentifier] = AppCandidate(bundleIdentifier: app.bundleIdentifier, name: app.displayName, running: nil)
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = byID[bundleID]?.name ?? app.localizedName ?? bundleID
            byID[bundleID] = AppCandidate(bundleIdentifier: bundleID, name: name, running: app)
        }
        return Array(byID.values)
    }

    /// One walk at a time: a new one cancels the last, and the walker's own
    /// serial queue keeps them from overlapping.
    private func loadMenus() {
        menuWalk?.cancel()
        menuWalk = nil
        guard preferences.isOn(.menus), AXIsProcessTrusted(), let pid = targetApp?.processIdentifier else { return }
        let walk = CommandBarMenuWalk()
        menuWalk = walk
        let expected = generation
        CommandBarMenus.load(pid: pid, walk: walk) { items in
            let service = CommandBarService.shared
            guard service.isPresented, service.generation == expected, service.menuWalk === walk else { return }
            service.menuItems = items
            service.recompute()
        }
    }

    /// The focused window of the app in front, read off the main queue with
    /// a short timeout so a hung app cannot stall the dock, then matched
    /// against the registry's snapshot on the main queue. Only needed for
    /// snap rows.
    private func resolveTargetWindow() {
        guard preferences.isOn(.snap), AXIsProcessTrusted(), let pid = targetApp?.processIdentifier else { return }
        let expected = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            var focused: AXUIElement?
            if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                focused = (value as! AXUIElement)
            }
            // Same rule as WindowRegistry.frontmostWindow: fall back to the
            // app's latest window only when it reports no focused window,
            // never when it timed out.
            let mayFallBack = status != .success && status != .cannotComplete
            let box = CommandBarElementBox(element: focused)
            DispatchQueue.main.async {
                let service = CommandBarService.shared
                guard service.isPresented, service.generation == expected else { return }
                let windows = WindowRegistry.shared.windows
                if let element = box.element {
                    service.targetWindow = windows.first { CFEqual($0.element, element) }
                } else if mayFallBack {
                    service.targetWindow = windows.first { $0.processIdentifier == pid && !$0.isMinimized }
                }
                if service.targetWindow != nil { service.recompute() }
            }
        }
    }

    // MARK: - Files

    private func scheduleFileSearch() {
        fileDebounce?.cancel()
        stopFileQuery()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.isOn(.files), text.count >= 2, text.count <= 100 else { return }
        let work = DispatchWorkItem { [weak self] in self?.startFileQuery(text) }
        fileDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Where Spotlight looks: the home folder (only when it is on a local
    /// disk, never a network home) and /Applications. Library is left out.
    private var fileRoots: (scopes: [URL], roots: [String], excluded: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var scopes = [applications]
        if homeIsLocal { scopes.insert(home, at: 0) }
        return (scopes, scopes.map(\.path), [home.appendingPathComponent("Library").path])
    }

    /// Spotlight within `fileRoots`. The typed text is passed as a predicate
    /// argument, never spliced into the format string. Partial results are
    /// shown as they gather; the query stops once it has enough, when it
    /// finishes, or at a one second deadline, whichever comes first.
    private func startFileQuery(_ text: String) {
        guard isPresented else { return }
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = fileRoots.scopes
        metadataQuery.predicate = NSPredicate(
            format: "%K CONTAINS[cd] %@ AND %K != %@",
            NSMetadataItemDisplayNameKey, text,
            NSMetadataItemContentTypeKey, "com.apple.application-bundle"
        )
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        metadataQuery.notificationBatchingInterval = 0.15
        let expected = generation
        for (name, isFinal) in [(Notification.Name.NSMetadataQueryGatheringProgress, false),
                                (Notification.Name.NSMetadataQueryDidFinishGathering, true)] {
            fileQueryObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: metadataQuery,
                queue: .main
            ) { [weak self] _ in
                self?.collectFiles(from: metadataQuery, text: text, generation: expected, isFinal: isFinal)
            })
        }
        fileQuery = metadataQuery
        guard metadataQuery.start() else {
            stopFileQuery()
            return
        }
        let deadline = DispatchWorkItem { [weak self] in
            self?.collectFiles(from: metadataQuery, text: text, generation: expected, isFinal: true)
        }
        fileDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: deadline)
    }

    private func collectFiles(from metadataQuery: NSMetadataQuery, text: String, generation expected: Int, isFinal: Bool) {
        guard isPresented, generation == expected, fileQuery === metadataQuery,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        let limit = preferences.maxResults
        let (_, roots, excluded) = fileRoots
        metadataQuery.disableUpdates()
        // Only a bounded prefix is ever looked at, however much Spotlight found.
        let scanned = min(metadataQuery.resultCount, limit * 8)
        var urls: [URL] = []
        for index in 0..<scanned where urls.count < limit {
            guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  CommandBarFileFilter.isAllowed(path: path, roots: roots, excluded: excluded) else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        if isFinal || urls.count >= limit {
            stopFileQuery()
        } else {
            metadataQuery.enableUpdates()
        }
        fileResults = urls
        fileResultsQuery = text
        recompute()
    }

    private func stopFileQuery() {
        fileDeadline?.cancel()
        fileDeadline = nil
        fileQuery?.stop()
        fileQuery = nil
        for observer in fileQueryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        fileQueryObservers = []
    }

    // MARK: - Helpers

    private static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private static func openApp(bundleIdentifier: String, running: NSRunningApplication?) -> Bool {
        if let running, !running.isTerminated {
            running.unhide()
            return running.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    // MARK: - Shortcut conflicts

    /// Why `shortcut` cannot open the bar, or nil when it is free. Covers
    /// every global combination Wharf already owns, including each window
    /// snap shortcut.
    func conflictMessage(for shortcut: KeyboardShortcut) -> String? {
        guard shortcut.isValid else { return nil }
        let wharf = DockyPreferences.shared

        var reserved: [(name: String, shortcut: KeyboardShortcut)] = [
            // StartMenuService registers Control-Option-S unconditionally.
            ("the Start Menu shortcut", KeyboardShortcut(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.control, .option])),
        ]
        if wharf.launchpadShortcut.isValid {
            reserved.append(("the Launchpad shortcut", wharf.launchpadShortcut))
        }
        let switcher = wharf.windowSwitcherShortcut
        if switcher.isValid {
            reserved.append(("the Window Switcher shortcut", switcher))
            reserved.append((
                "the Window Switcher reverse shortcut",
                KeyboardShortcut(keyCode: switcher.keyCode, modifierFlags: switcher.modifierFlags.union(.shift))
            ))
        }
        if wharf.windowsKeyboardMode, wharf.windowsKeyboardSnipShortcut {
            reserved.append((
                "the Windows snip shortcut",
                KeyboardShortcut(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.command, .shift])
            ))
        }

        var assigned: [WindowSnapAction: KeyboardShortcut] = [:]
        for action in WindowSnapAction.allCases {
            if let existing = wharf.windowSnapShortcut(for: action) { assigned[action] = existing }
        }

        switch WindowSnapShortcuts.conflict(for: shortcut, excluding: nil, assigned: assigned, reserved: reserved) {
        case .action(let action):
            return "\(shortcut.displayString) is already used by the \(action.title) snap shortcut."
        case .reserved(let name):
            return "\(shortcut.displayString) is already used by \(name)."
        case nil:
            break
        }

        let flags = shortcut.modifierFlags
        if wharf.windowsKeyboardMode,
           flags.contains(.control),
           !flags.contains(.command),
           WindowsKeyboardService.translatedKeyCodes.contains(Int64(shortcut.keyCode)) {
            return "Windows Keyboard Mode turns Control plus this key into Command, so \(shortcut.displayString) would never arrive."
        }
        return nil
    }

    // MARK: - Hot key

    private func registerHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        var unavailable = false
        let shortcut = preferences.shortcut
        // Re-checked on every registration, so a setting changed elsewhere
        // after the shortcut was recorded is caught and shown in the pane.
        let conflict = preferences.enabled && shortcut.isValid ? conflictMessage(for: shortcut) : nil
        if conflict != activeConflictMessage {
            activeConflictMessage = conflict
        }
        if preferences.enabled, !isRecordingShortcut, shortcut.isValid, conflict == nil {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.carbonModifierFlags,
                EventHotKeyID(signature: Self.hotKeySignature, id: 1),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRef = ref
            } else {
                unavailable = true
            }
        }
        if !preferences.enabled { dismiss() }
        if unavailable != isShortcutUnavailable {
            isShortcutUnavailable = unavailable
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == CommandBarService.hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in
                CommandBarService.shared.toggle()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, nil, &hotKeyHandlerRef)
    }
}

/// Carries an AX element from the background read to the main queue.
private nonisolated struct CommandBarElementBox: @unchecked Sendable {
    let element: AXUIElement?
}
