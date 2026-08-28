//
//  WindowsKeyboardService.swift
//  Wharf
//
//  Translates Windows keyboard shortcuts into their macOS equivalents.
//
//  macOS already remaps a PC keyboard's physical keys: Win becomes Command,
//  Alt becomes Option. That means Win+C copies and Ctrl+C does nothing, which
//  is backwards from every Windows reflex. This service rewrites Control into
//  Command for the standard editing shortcuts, and turns Win+Shift+S into a
//  region capture on the clipboard, the way the Windows snip works.
//

import AppKit
import Carbon.HIToolbox
import Combine

final class WindowsKeyboardService {
    static let shared = WindowsKeyboardService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables: Set<AnyCancellable> = []

    /// The tap's own thread and runloop.
    ///
    /// Wharf: this used to run on the main runloop, which put every keystroke
    /// on the system behind whatever the dock's UI happened to be doing. A
    /// head-inserted tap has a deadline: take too long and macOS stops waiting
    /// and drops the event. Typing "Thanks for the update." while the dock was
    /// busy produced "Ks for the ute.p" — characters lost, one arriving late
    /// and out of order. Measured: 8 of 8 sentences typed cleanly with the tap
    /// off, and half of them mangled with it on.
    ///
    /// A dedicated thread means the input path no longer waits on drawing.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    /// Everything the callback needs, behind a lock, so it never reaches into
    /// main-actor state from the tap thread.
    private let stateLock = NSLock()
    private var _snipEnabled = false
    private var _excludedBundleIDs: Set<String> = []

    /// Frontmost bundle ID, cached. The exclusion check runs on every
    /// keystroke, and asking NSWorkspace each time would put a cross-process
    /// lookup in the input path.
    private var _frontmostBundleID: String?

    /// Written from the main thread, read from the tap thread.
    private var frontmostBundleID: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _frontmostBundleID }
        set { stateLock.lock(); _frontmostBundleID = newValue; stateLock.unlock() }
    }

    private var snipEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _snipEnabled }
        set { stateLock.lock(); _snipEnabled = newValue; stateLock.unlock() }
    }

    private var excludedBundleIDs: Set<String> {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _excludedBundleIDs }
        set { stateLock.lock(); _excludedBundleIDs = newValue; stateLock.unlock() }
    }

    /// Pulls the preferences the callback depends on into the snapshot. Called
    /// on the main thread whenever they change.
    @MainActor
    private func refreshSnapshot() {
        snipEnabled = DockyPreferences.shared.windowsKeyboardSnipShortcut
        excludedBundleIDs = Set(DockyPreferences.shared.windowsKeyboardExcludedBundleIDs)
    }

    /// Guards against autorepeat launching a second region capture while the
    /// first crosshair is still up.
    private var isSnipInFlight = false

    /// Keys that mean the same thing on Windows with Control as they do on
    /// macOS with Command.
    ///
    /// Q is deliberately absent: Ctrl+Q is not a Windows quit shortcut, and
    /// rewriting it would turn a harmless keystroke into "quit the app".
    private static let translatedKeyCodes: Set<Int64> = [
        Int64(kVK_ANSI_A),      // select all
        Int64(kVK_ANSI_B),      // bold
        Int64(kVK_ANSI_C),      // copy
        Int64(kVK_ANSI_D),      // duplicate / bookmark
        Int64(kVK_ANSI_E),      // focus search bar
        Int64(kVK_ANSI_F),      // find
        Int64(kVK_ANSI_I),      // italic
        Int64(kVK_ANSI_L),      // focus address bar
        Int64(kVK_ANSI_N),      // new
        Int64(kVK_ANSI_O),      // open
        Int64(kVK_ANSI_P),      // print
        Int64(kVK_ANSI_R),      // reload
        Int64(kVK_ANSI_S),      // save
        Int64(kVK_ANSI_T),      // new tab
        Int64(kVK_ANSI_U),      // underline
        Int64(kVK_ANSI_V),      // paste
        Int64(kVK_ANSI_W),      // close tab
        Int64(kVK_ANSI_X),      // cut
        Int64(kVK_ANSI_Y),      // redo
        Int64(kVK_ANSI_Z)       // undo
    ]

    private init() {}

    // MARK: - Lifecycle

    /// Starts translating if the preference is on, and keeps watching the
    /// preference so the tap follows it without a relaunch.
    func start() {
        observeFrontmostApplication()
        observePreference()
        observeAccessibilityPermission()
        syncTapState()
    }

    /// Accessibility can be granted after launch, and an event tap created
    /// without it silently does nothing. Re-sync whenever the grant changes so
    /// the feature arms itself the moment permission lands, instead of
    /// requiring a relaunch nobody would know to perform.
    private func observeAccessibilityPermission() {
        PermissionsService.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncTapState()
            }
            .store(in: &cancellables)
    }

    /// Where the service records what it decided and why.
    ///
    /// This exists because the failure modes here are all silent: a tap
    /// without permission, a permission grant invalidated by a new build
    /// signature, or a preference that never reached the app all look
    /// identical from the outside, which is "my keyboard just doesn't work".
    private static var statusFileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Wharf/wharf-keyboard-status.txt")
    }

    private func writeStatus(_ message: String) {
        guard let url = Self.statusFileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = "\(Date()) \(message)\n"
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }

    private func syncTapState() {
        MainActor.assumeIsolated { refreshSnapshot() }
        guard DockyPreferences.shared.windowsKeyboardMode else {
            writeStatus("OFF: windowsKeyboardMode preference is false")
            removeTap()
            return
        }

        // `AXIsProcessTrusted()` is the authority the event tap itself answers
        // to. PermissionsService caches a value that can lag behind a grant
        // made moments ago, and a stale "denied" would leave the feature off
        // with nothing logged to explain why.
        guard AXIsProcessTrusted() else {
            writeStatus("BLOCKED: Accessibility not granted to this build (AXIsProcessTrusted == false). A rebuilt binary gets a new signature, which invalidates an existing grant even though System Settings still shows the toggle on. Toggle Wharf off and on in Privacy & Security > Accessibility.")
            removeTap()
            return
        }

        installTapIfNeeded()
    }

    private func observePreference() {
        withObservationTracking {
            _ = DockyPreferences.shared.windowsKeyboardMode
            _ = DockyPreferences.shared.windowsKeyboardSnipShortcut
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncTapState()
                self.observePreference()
            }
        }
    }

    private func observeFrontmostApplication() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
        }
    }

    // MARK: - Event tap

    private func installTapIfNeeded() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        // `.cgSessionEventTap` at `.headInsertEventTap` so the rewrite happens
        // before any application sees the keystroke. The tap must be active
        // (not listen-only) to modify or swallow events.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowsKeyboardService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Wharf] Windows keyboard mode: failed to create event tap (Accessibility permission missing?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        // Onto its own thread, not the main runloop. Keystrokes must not wait
        // behind the dock's drawing; see the note on `tapThread`.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.tapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // A source alone does not keep a runloop alive; the port does.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        thread.name = "wharf.windows-keyboard.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        _ = ready.wait(timeout: .now() + 2)
        writeStatus("ACTIVE: event tap installed; Control translates to Command, terminals excluded.")
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource, let tapRunLoop {
                CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
                CFRunLoopWakeUp(tapRunLoop)
            }
            CFMachPortInvalidate(eventTap)
        }
        tapThread?.cancel()
        if let tapRunLoop { CFRunLoopWakeUp(tapRunLoop) }
        tapThread = nil
        tapRunLoop = nil
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Translation

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or that the user
        // revoked permission for. Re-arm rather than silently going dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Win+Shift+S. The Win key already arrives as Command, so this reads
        // as Cmd+Shift+S. Swallowed rather than forwarded, otherwise the app
        // underneath also runs its Save As.
        // Clear the latch on any S release. Releasing the Win key before S
        // means the chord no longer matches, so a latch that only cleared
        // inside the matching branch would stay set and kill every later snip.
        if type == .keyUp, keyCode == Int64(kVK_ANSI_S) {
            isSnipInFlight = false
        }

        if snipEnabled,
           shouldTranslateControl(),
           keyCode == Int64(kVK_ANSI_S),
           flags.contains(.maskCommand),
           flags.contains(.maskShift),
           !flags.contains(.maskControl),
           !flags.contains(.maskAlternate) {
            // Autorepeat fires this many times a second while the key is held.
            // Without the guard, leaning on the shortcut spawns a pile of
            // screencapture processes, each grabbing the screen in turn.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat, !isSnipInFlight {
                isSnipInFlight = true
                captureRegionToClipboard()
            }
            if type == .keyUp {
                isSnipInFlight = false
            }
            return nil
        }

        guard shouldTranslateControl() else {
            return Unmanaged.passUnretained(event)
        }

        // Control to Command, for the editing set only. Chords that already
        // carry Command are left alone: they were deliberate macOS shortcuts,
        // not Windows reflexes.
        guard flags.contains(.maskControl),
              !flags.contains(.maskCommand),
              Self.translatedKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        event.flags = flags.subtracting(.maskControl).union(.maskCommand)
        return Unmanaged.passUnretained(event)
    }

    /// False inside terminals, where Control must keep its Unix meaning.
    /// Ctrl+C there is SIGINT; rewriting it would remove the ability to
    /// interrupt a running process.
    private func shouldTranslateControl() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let bundleID = _frontmostBundleID else { return true }
        return !_excludedBundleIDs.contains(bundleID)
    }

    // MARK: - Snip

    /// Interactive region capture straight to the clipboard, matching what
    /// Win+Shift+S does on Windows: crosshair, drag a region, result is on the
    /// clipboard ready to paste.
    ///
    /// Shells out to the system `screencapture` rather than reimplementing the
    /// selection UI, so the crosshair, window snapping, escape-to-cancel and
    /// Space-to-grab-a-window all behave exactly as macOS users expect.
    private func captureRegionToClipboard() {
        // Launched off the tap callback. The callback runs on the main runloop
        // and the system disables an event tap that takes too long to return,
        // so a slow fork/exec here would cost the user their keyboard.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i interactive selection, -c to clipboard, -x no shutter sound.
            process.arguments = ["-i", "-c", "-x"]
            do {
                try process.run()
            } catch {
                NSLog("[Wharf] Windows keyboard mode: region capture failed: \(error.localizedDescription)")
            }
        }
    }
}
