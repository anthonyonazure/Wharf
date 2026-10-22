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
        let perform: () -> Void
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
}

final class CommandBarService: ObservableObject {
    static let shared = CommandBarService()

    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    @Published private(set) var results: [CommandBarResult] = []
    @Published var selectedIndex = 0
    @Published private(set) var showsActions = false
    @Published var actionIndex = 0
    /// True when the shortcut could not be registered, almost always because
    /// another app (Raycast, Alfred) holds it. Shown in the settings pane.
    @Published private(set) var isShortcutUnavailable = false

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
    private var fileResults: [URL] = []
    private var fileQuery: NSMetadataQuery?
    private var fileQueryObserver: NSObjectProtocol?
    private var fileDebounce: DispatchWorkItem?
    private var generation = 0

    private struct AppCandidate {
        let bundleIdentifier: String
        let name: String
        let running: NSRunningApplication?
    }

    private init() {}

    func start() {
        installHotKeyHandlerIfNeeded()
        observeChanges { [weak self] in
            _ = CommandBarPreferences.shared.enabled
            _ = CommandBarPreferences.shared.shortcut
            self?.registerHotKey()
        }
        .store(in: &cancellables)
    }

    // MARK: - Presentation

    func toggle() {
        isPresented ? dismiss() : present()
    }

    func present() {
        guard preferences.enabled else { return }
        generation += 1
        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        targetWindow = AXIsProcessTrusted() ? WindowRegistry.shared.frontmostWindow() : nil
        appCandidates = preferences.isOn(.apps) ? Self.collectApps() : []
        menuItems = []
        fileResults = []
        showsActions = false
        actionIndex = 0
        query = ""
        recompute()
        isPresented = true
        loadMenus()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        generation += 1
        stopFileQuery()
        menuItems = []
        appCandidates = []
        showsActions = false
    }

    // MARK: - Keyboard

    func moveSelection(by delta: Int) {
        if showsActions {
            let count = selectedResult?.actions.count ?? 0
            guard count > 0 else { return }
            actionIndex = (actionIndex + delta + count) % count
        } else {
            guard !results.isEmpty else { return }
            selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        }
    }

    /// Tab: open or close the quick-action list of the selected row.
    func toggleActions() {
        guard let result = selectedResult, result.actions.count > 1 || showsActions else { return }
        showsActions.toggle()
        actionIndex = 0
    }

    /// Escape closes the action list first, then the bar.
    func cancel() {
        if showsActions {
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

    func run(_ result: CommandBarResult, actionAt index: Int = 0) {
        guard result.actions.indices.contains(index) else { return }
        let action = result.actions[index]
        if let key = result.recencyKey {
            preferences.recordUse(key)
        }
        dismiss()
        // Let the panel go first, so a menu command or snap lands on the
        // app the user was in, not on the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            action.perform()
        }
    }

    var selectedResult: CommandBarResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    // MARK: - Results

    private func queryDidChange() {
        showsActions = false
        selectedIndex = 0
        recompute()
        scheduleFileSearch()
    }

    private func recompute() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = preferences.maxResults
        var rows: [CommandBarResult] = []

        if preferences.isOn(.calculator), let calc = CommandBarCalculator.evaluate(text) {
            rows.append(calculationRow(calc, expression: text))
        }
        if preferences.isOn(.units), let conversion = CommandBarUnits.convert(text) {
            rows.append(conversionRow(conversion, input: text))
        }

        let local = rankedLocalRows(query: text, limit: limit)
        let files = text.count >= 2 ? fileResults.map(fileRow) : []
        // Files keep a few rows for themselves; local rows fill the rest.
        let fileShare = files.isEmpty ? 0 : min(files.count, max(2, limit / 3))
        rows += local.prefix(max(0, limit - rows.count - fileShare))
        rows += files.prefix(max(0, limit - rows.count))

        results = Array(rows.prefix(limit))
        // Results that arrive later (menus, files) keep the user's place.
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, results.count - 1)
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

        let targetBundleID = targetApp?.bundleIdentifier ?? "unknown"
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
                case .menu(let item, _): Self.menuKey(item, bundleID: targetBundleID)
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

    private static func menuKey(_ item: CommandBarMenuItem, bundleID: String) -> String {
        "menu:\(bundleID):\(item.path.joined(separator: " > ")) > \(item.title)"
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
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
        ]
        if let running {
            actions.append(.init(title: "Hide", symbolName: "eye.slash") { running.hide() })
            actions.append(.init(title: "Quit", symbolName: "xmark.circle") { running.terminate() })
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
                WindowSnapService.shared.perform(action, on: window)
                _ = WindowRegistry.shared.focus(window)
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
                .init(title: "Bring to Front", symbolName: "macwindow") { _ = WindowRegistry.shared.focus(window) },
                .init(title: "Minimize", symbolName: "minus.circle") { _ = WindowRegistry.shared.minimize(window) },
                .init(title: "Close", symbolName: "xmark.circle") { _ = WindowRegistry.shared.close(window) },
                snap(.leftHalf),
                snap(.rightHalf),
                snap(.maximize),
            ]
        )
    }

    private func menuRow(_ item: CommandBarMenuItem, index: Int) -> CommandBarResult {
        let appName = targetApp?.localizedName ?? "App"
        let bundleID = targetApp?.bundleIdentifier ?? "unknown"
        let path = item.path.joined(separator: " > ")
        return CommandBarResult(
            // Two items can share a path and title, so the index keeps rows unique.
            id: "menu:\(index):\(path) > \(item.title)",
            kind: .menu,
            title: item.title,
            subtitle: "\(appName): \(path)",
            icon: nil,
            symbolName: "filemenu.and.selection",
            accessory: item.shortcut,
            recencyKey: Self.menuKey(item, bundleID: bundleID),
            actions: [
                .init(title: "Run Command", symbolName: "return") { CommandBarMenus.press(item) },
            ]
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
                    WindowSnapService.shared.perform(action, on: window)
                },
            ]
        )
    }

    private func fileRow(_ url: URL) -> CommandBarResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = url.deletingLastPathComponent().path
        if folder.hasPrefix(home) { folder = "~" + folder.dropFirst(home.count) }
        return CommandBarResult(
            id: "file:\(url.path)",
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

    private func loadMenus() {
        guard preferences.isOn(.menus), AXIsProcessTrusted(), let pid = targetApp?.processIdentifier else { return }
        let expected = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let items = CommandBarMenus.items(for: pid)
            DispatchQueue.main.async {
                let service = CommandBarService.shared
                guard service.isPresented, service.generation == expected else { return }
                service.menuItems = items
                service.recompute()
            }
        }
    }

    // MARK: - Files

    private func scheduleFileSearch() {
        fileDebounce?.cancel()
        stopFileQuery()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.isOn(.files), text.count >= 2, text.count <= 100 else {
            if !fileResults.isEmpty {
                fileResults = []
                recompute()
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.startFileQuery(text) }
        fileDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Spotlight on this Mac's local disks only. The typed text is passed as
    /// a predicate argument, never spliced into the format string.
    private func startFileQuery(_ text: String) {
        guard isPresented else { return }
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        metadataQuery.predicate = NSPredicate(
            format: "%K CONTAINS[cd] %@ AND %K != %@",
            NSMetadataItemDisplayNameKey, text,
            NSMetadataItemContentTypeKey, "com.apple.application-bundle"
        )
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        let expected = generation
        fileQueryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == expected, self.fileQuery === metadataQuery else { return }
            metadataQuery.disableUpdates()
            let cap = min(metadataQuery.resultCount, self.preferences.maxResults)
            var urls: [URL] = []
            for index in 0..<cap {
                guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                urls.append(URL(fileURLWithPath: path))
            }
            self.stopFileQuery()
            self.fileResults = urls
            self.recompute()
        }
        fileQuery = metadataQuery
        if !metadataQuery.start() {
            stopFileQuery()
        }
    }

    private func stopFileQuery() {
        fileQuery?.stop()
        fileQuery = nil
        if let fileQueryObserver {
            NotificationCenter.default.removeObserver(fileQueryObserver)
            self.fileQueryObserver = nil
        }
    }

    // MARK: - Helpers

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func openApp(bundleIdentifier: String, running: NSRunningApplication?) {
        if let running, !running.isTerminated {
            running.unhide()
            running.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
        if preferences.enabled, !isRecordingShortcut, shortcut.isValid {
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
