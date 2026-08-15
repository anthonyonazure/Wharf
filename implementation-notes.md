# Implementation Notes

Running log for the Wharf build. Deviations from plan get recorded here as they
happen, with the conservative option taken and the reason stated.

## 2026-08-15 — Fork established

**Decision: hard fork of Docky rather than a GitHub fork or a clean-room build.**

Considered three bases:

| Candidate | Stars | License | Verdict |
| --- | --- | --- | --- |
| [Docky](https://github.com/josejuanqm/docky) | 1076 | GPL-3.0 | **Chosen.** Richest feature set, active, notarized, Sparkle updates already wired |
| [Tungsten Edge](https://github.com/moonbai-studio/tungsten-edge) | 100 | GPL-3.0 | Reference for per-window taskbar cards and blink-free fullscreen. Same license, so code can be borrowed |
| [meDock](https://github.com/metin-aksu/meDock) | 7 | MIT | Too small to bootstrap from |

Clean-room was rejected: rebuilding window enumeration, private SkyLight/CGS
positioning, live previews and notarization would cost months to reach where Docky
already is. GPL-3.0 is therefore inherited and permanent for anything distributed.

Full git history was preserved (310 commits) and upstream kept as a remote, so
upstream fixes merge instead of being reimplemented.

## The core problem: Docky assumes one dock

Survey of the codebase at fork time:

- `MainWindow` is effectively a singleton. Every overlay controller
  (`DockEditorOverlayWindowController`, `LaunchpadOverlayWindowController`,
  `WindowSwitcherOverlayWindowController`, `StartMenuOverlayWindowController`,
  `SmartOrganizeProgressChipWindowController`, `ProfileSwitcherWindowController`)
  takes `mainWindow:` as a construction dependency — see
  `Docky/Views/MainWindow/MainWindowController.swift`.
- 23 references to `NSScreen.main` and 18 to `NSScreen.screens` across 18 files.
  `NSScreen.main` is the load-bearing assumption: it means "the screen with the
  focused window", not "the screen this dock belongs to".
- `WindowReservationService` and `SkyLightSpaceReservationProbe` reserve screen
  space for one dock.

**Shape of the fix:** convert an implicit singleton into one instance per screen.
A `ScreenDockCoordinator` owns a map of `NSScreen` identity to dock instance,
observes `NSApplication.didChangeScreenParametersNotification` for
connect/disconnect, and every `NSScreen.main` call site is re-pointed at the screen
its own dock owns. Overlay controllers stop taking "the" main window and start
taking "their" main window.

**Screen identity gotcha to watch:** `NSScreen` objects are replaced on display
reconfiguration, so they cannot be used as stable dictionary keys. Docks must be
keyed on the display's persistent ID (`NSScreenNumber` from `deviceDescription`, or
the CGDirectDisplayID UUID) or per-display settings will be lost every time a
monitor sleeps or is unplugged. ExtraDock's "stays where it belongs even after you
unplug and reconnect" is exactly this problem solved.

## 2026-08-15 — Multi-display shipped

Verified live on a three-display desk (LG HDR 4K primary, built-in Liquid Retina
XDR, LG ULTRAFINE): three docks visible simultaneously, one per screen.

What changed:

- `DockWindowDisplayTarget` gained `.allDisplays`, plus `usesSingleWindow` so the
  two legacy modes keep their exact old behavior.
- `MainWindow.assignedDisplayID` binds a window to a display. `targetScreen()`
  short-circuits on it, which was the whole trick: every frame calculation in the
  window already routed through that one function, so binding it there converted
  "the dock" into "this screen's dock" without touching layout code.
- Pointer-follow monitors are suppressed on bound windows.
- `ScreenDockCoordinator` reconciles the live window set against attached displays
  and the current preference, on `didChangeScreenParametersNotification`.
- `WindowReservationService.scan` looped over every dock instead of `.first`.
  Upstream's `.first` was correct for one dock and would have left every
  non-primary screen unprotected against maximized windows.
- `AppDelegate` no longer owns a dock window.

### Verification gotcha worth remembering

`nm` and `strings` on the linked app binary reported zero matches for the new
class, which looked like the file had not compiled. It had. Swift internal symbols
are stripped from the executable's export table, and `String(localized:)` text
lives in the string catalog rather than the binary. The honest checks are the
compile file list (`Docky.SwiftFileList`), the object file
(`ScreenDockCoordinator.o`, 74 symbols), and actual runtime behavior.

Also: building this project publishes a copy to `/Applications/Docky.app`, so
`open` may launch that rather than the DerivedData product. They are byte-identical
per `shasum`, but check before concluding which binary is under test.

### Known limitations (not yet addressed)

- `DockLayoutService`, `DockMagnificationService` and `TileStore` are process-wide
  singletons, so all docks currently share one layout, one magnification state and
  one set of tiles. Per-screen tile sets and per-screen themes need those made
  instance-scoped. This is the next structural piece.
- Every dock shows all apps. Per-screen filtering (show only windows on this
  screen) is a separate feature that depends on the same instance-scoping work.

## 2026-08-15 — Windows keyboard mode

Requested because a PC keyboard is connected: macOS maps its Win key to Command,
so Win+C copies and Ctrl+C does nothing, which is backwards from every Windows
reflex.

`WindowsKeyboardService` installs a `.cgSessionEventTap` at `.headInsertEventTap`
and rewrites Control into Command for the standard editing set (20 keys), plus
turns Win+Shift+S into an interactive region capture on the clipboard by shelling
out to `screencapture -i -c -x`.

Verified end to end:

| Behavior | Result |
| --- | --- |
| Ctrl+C in TextEdit | copied |
| Ctrl+V in TextEdit | pasted |
| Win+Shift+S | interactive region capture launched, Escape cancels |
| Ctrl+C in Terminal | **not** translated, clipboard untouched, SIGINT preserved |

Q is deliberately excluded from translation: Ctrl+Q is not a Windows shortcut, and
translating it would turn a harmless keystroke into "quit the app".

### Known limitation: apps with embedded terminals

The exclusion list works on the frontmost app's bundle ID, which is the finest
granularity an event tap gets. VS Code is one bundle ID whether focus is in the
editor or the integrated terminal, so Ctrl+C there is translated to copy and will
not send SIGINT. Add `com.microsoft.VSCode` to
`wharf.windowsKeyboardExcludedBundleIDs` to flip that trade the other way.
Distinguishing focus within an app needs a driver (what Karabiner uses), not a
userspace tap.

### Two verification traps that cost real time here

**1. AppleScript keystrokes are not a valid test of an event tap.**
`tell application "System Events" to key code 8 using control down` enters the
event stream downstream of a session tap, so a working tap appears to do nothing.
Post at the HID tap point instead (`CGEvent.post(tap: .cghidEventTap)`), which is
where a physical keypress enters. `postkey.swift` in the session scratchpad does
this.

**2. Debug builds hide their code in a dylib, so `shasum` on the executable lies.**
The app moves itself to `/Applications` on first launch
(`ApplicationInstallService.promptToMoveToApplicationsIfNeeded`), after which
`xcodebuild` only ever updates DerivedData. Comparing
`Contents/MacOS/Docky` between the two reported identical hashes and looked like
proof they were the same build. They were not: that file is a 40 KB stub, and the
real 28 MB of code sits beside it in `Docky.debug.dylib`, which was 15 minutes
stale. Every test in between was run against a binary that predated the feature.
After each build, install with
`ditto <DerivedData>/Debug/Docky.app /Applications/Docky.app`, and compare the
dylib's timestamp, not the stub's hash.

Because these failures are silent, the service now writes its decision to
`~/Library/Application Support/Docky/wharf-keyboard-status.txt` (ACTIVE / BLOCKED /
OFF), and the settings pane shows a warning with a permission button when the
mode is on but Accessibility is missing.

## Deviations

**Settings copy for the display picker was rewritten.** Upstream's text asserts
"Docky uses a single main window", which stopped being true. Conservative option
taken: reword rather than restructure the settings layout.
