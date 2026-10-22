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

## Clicks and permissions, 2026-08-26

Two reports: the dock did not always accept clicks, and macOS kept asking for
screen-recording permission on every snip. Three distinct causes.

### 1. Signing: the app was ad-hoc, so every rebuild reset its permissions

`DEVELOPMENT_TEAM` was still upstream Docky's `2KC3797KP9`, a team with no
certificate on this machine, so every build silently fell back to an ad-hoc,
linker-signed bundle: no team identifier, no sealed resources, no designated
requirement. TCC stores a code requirement beside each grant. With no designated
requirement it can only store the executable's cdhash, so the grant matched one
build and nothing after it, while System Settings still drew the toggle as on.

Confirmed against the live database rather than inferred. `csreq` for
`kTCCServiceScreenCapture` was the cdhash of a binary that no longer existed,
which is why capture prompted every time, and `kTCCServiceAccessibility` happened
to still match, which is why keyboard mode worked and capture did not.

Fixed by setting `DEVELOPMENT_TEAM = 4P54C2K45P` (the OU of the installed Apple
Development certificate, not the `NY74J2RQ57` shown in its common name). The
bundle now signs with hardened runtime and a designated requirement of
identifier + Apple anchor + leaf certificate, so grants survive every rebuild
until the certificate itself rotates (2027-05-04).

Old cdhash-pinned rows had to be cleared once with `tccutil reset` so TCC would
record the new requirement.

### 2. Reorder drag stole ordinary clicks

`TileContainerView.reorderGesture` used `DragGesture(minimumDistance: 4)`
alongside the tile's own `onTapGesture`. Four points is inside ordinary click
jitter: a mouse that drifts five points between press and release recognizes the
drag, SwiftUI cancels the tap, and the click does nothing at all. Raised to 10,
which is AppKit's own drag slop.

### 3. Stay-behind dropped every dock, not the one being covered

The stacking rule for remote-desktop clients set the window level on whichever
dock received `didActivateApplicationNotification`, which is all of them. Bringing
a remote session forward on one display buried the docks on the other two
underneath ordinary windows, where they were still drawn but no longer took
clicks. `updateStackingForFrontmostApp` now takes the running application and
only yields when that process actually has a window overlapping this dock's own
screen.

### 4. The click: taken off SwiftUI gestures entirely

The tile's activation was an `onTapGesture` nested inside the container's
reorder `DragGesture`. SwiftUI has to arbitrate between the two on every
press, and the measurements in HANDOFF.md show it losing: about half of the
releases that arrived lost the arbitration, and the drag's own event-tracking
loop swallowed two of nineteen releases outright. Raising the drag threshold,
zero-distance drags and hover-identified presses were all tried and all failed
for reasons recorded there.

Tiles whose whole surface is one target (apps, folders, launchpad, start menu,
trash, minimized windows) now carry no gesture at all. `TilePressService`
reads the press, the drag and the release from one AppKit event monitor, where
nothing competes for them, resolves the tile by hit-testing the press against
the frames the container publishes, and calls the tile's action on release.
The reorder drag for those tiles is driven from the same monitor.

Widget and smart-stack tiles keep their SwiftUI gestures. They contain their
own controls (transport buttons, join-meeting, a text field); SwiftUI stops a
tap at the control that handled it and an AppKit monitor cannot know that
happened, so routing those would fire the tile's action on top of every button
press inside them.

Why the earlier attempt at frame hit-testing matched "correctly in one run and
not the next": SwiftUI's `.global` space starts at the top-left of the
`NSHostingView`, which `MainWindowContainerView` insets from the window edge by
a user-adjustable amount. A press converted against the window is off by
whatever the content insets happen to be. `TileClickRouter` is therefore keyed
by the hosting view and the press is converted against that view, which needs
no assumption about chrome. The same key stops three docks publishing the same
tile IDs over each other.

## 2026-10-22, Stage 1: window snapping

Keyboard window snapping at parity with Vorssaint's Window Layout, adapted from
Vorssaint (vorssaint/vorssaint-utils, GPL-3.0). Files:

- `Docky/Services/WindowSnapGeometry.swift`: pure math (Foundation and
  CoreGraphics only). `WindowSnapAction` (41 actions), `targetRect(for:current:area:gap:)`,
  `subtractingDock(_:from:)`, `rectForDisplay(current:source:destination:)`,
  `anchoredRect`, `adjacentDisplayIndex`, `WindowSnapHistory`, and the
  shortcut resolution and conflict helpers.
- `Docky/Services/WindowSnapAction+Shortcuts.swift`: default shortcuts.
- `Docky/Services/WindowSnapService.swift`: the single entry point is
  `WindowSnapService.shared.perform(_:on:)`; `on: nil` means the frontmost
  window. Also owns the Carbon hot keys and `conflictMessage(for:action:)`.
- `WindowRegistry` gained `frontmostWindow()`, `liveFrame(of:)` and `move(_:to:)`.
- `Docky/Views/SettingsWindow/WindowSnappingSettingsView.swift`: the pane,
  registered under Features in `SettingsRootView`.
- Prefs: `wharf.windowSnapEnabled` (default on), `wharf.windowSnapGap`
  (default 0, clamped 0 to 40), `wharf.windowSnapShortcuts` (JSON map of only
  the user's overrides; a stored empty shortcut means "cleared").

Order of operations for a snap: screen visibleFrame, minus the strip of every
visible Wharf dock on that screen (`MainWindow.currentReservationFrame`, same
edge rule as `WindowReservationService`), then the gap on the screen edges,
then the tile, then half the gap off each shared edge so neighbors end up
exactly one gap apart.

### How to run the geometry tests

The Xcode project has no test target, and adding one here would mean hand
editing `project.pbxproj` while another branch is adding test infrastructure.
Instead the pure geometry compiles with a standalone check file:

    scripts/test-snap-geometry.sh

It needs only Xcode's Swift toolchain, builds `Docky/Services/WindowSnapGeometry.swift`
together with `Tests/WindowSnap/WindowSnapGeometryTests.swift` into a small
executable, and prints `PASS: 187 checks` or each failure with its line. The
`Tests/` folder sits outside the `Docky/` synchronized group, so the app build
never sees it.

### Deviations

- **Branch.** This work was done in an isolated worktree that cannot check out
  `feature/vorssaint-parity` (the main checkout holds it). The worktree branch
  `worktree-agent-ab2dc9840d62982eb` was reset to the tip of
  `feature/vorssaint-parity` (0ec26b5) and the commits sit on top of it. They
  need a fast-forward merge or cherry-pick onto `feature/vorssaint-parity`.
- **Display moves scale proportionally**, as the brief asked. Vorssaint
  deliberately does not: it keeps the window's size (only shrinking to fit)
  and its edge insets, because scaling stretches a laptop window across an
  ultrawide and squashes it onto a portrait panel. If that bites, swapping to
  Vorssaint's rule is a change to `rectForDisplay` alone.
- **One gap, not two.** Vorssaint has separate window and screen gaps; the
  brief asked for one, so the same value drives both. Following Vorssaint,
  Maximize takes the screen gap but no window gap, and Center, Maximize with
  Margin, Restore and the display moves ignore the gap.
- **Maximize with Margin** uses Vorssaint's fixed 5 percent inset per axis,
  with no separate setting.
- **Default shortcuts for Center and Restore differ from Vorssaint.**
  Vorssaint uses Control-Option-C and Control-Option-R, but Windows Keyboard
  Mode rewrites Control plus C or R into Command before the key reaches a hot
  key. Wharf uses Control-Option-M (center) and Control-Option-Delete
  (restore). Halves are Control-Option-arrows, Maximize Control-Option-Return,
  next and previous display Control-Option-Command-Right and Left. Everything
  else starts unset.
- **Conflict refusal also covers Windows Keyboard Mode.** When that mode is on,
  a Control shortcut (without Command) on a key the mode rewrites is refused,
  since it would arrive as Command instead. The window switcher's implicit
  Shift reverse shortcut and the Windows snip are refused too.
- **Edges are rounded, not `integral`.** Vorssaint rounds rects outward with
  `integral`, which made adjacent thirds overlap by a point and broke the
  exact gap. Each edge is rounded to the nearest point instead.
- **Thirds include Middle Two Thirds**, which Vorssaint lacks, because the
  brief lists two thirds for top, middle and bottom. Vorssaint's Full Screen
  action is not included (not in the brief).
- **Not ported on purpose:** Vorssaint's repeat-press behavior (Top Half
  twice maximizes, a repeated side half cycles half, two thirds, one third or
  crosses to the next display: `effectiveAction`, `displayCrossing`,
  `sideCycle*`), the directional display picker, and the ignored-apps list.
- **Right-click "Move and Resize" submenu not changed (brief item 5 skipped).**
  The existing submenu lives in `WindowContextActions.swift`, shared by the
  hover preview and the switcher, not the tile menu; its handlers still use
  `WorkspaceService.fill*`, which ignore the dock strip and the gap. Pointing
  them at `WindowSnapService.shared.perform(_:on:)` is a small follow-up.
- **The snap service is `@Observable`**, unlike the Combine-based services, so
  the pane can show which shortcuts another app already holds.

### Unverified

- Nothing was run against real windows. The Debug build was not launched,
  because starting a second Wharf alongside the installed one would put a
  second set of docks on screen and register the shortcuts system wide. So no
  snap, restore, display move, hot key press or settings pane has been seen.
- Whether a session event tap (Windows Keyboard Mode) rewrites a key before a
  Carbon hot key sees it was not tested; the conflict rule assumes it does.
- The dock strip uses `MainWindow.frame`, which may include magnification
  headroom, the same as `WindowReservationService`. If so, snapped windows
  stop short of the dock by that headroom.
- The dock-overshoot retry and the re-anchor for apps with a minimum size are
  ported logic, untested against an app that actually refuses a size.
- Snapping with a dock that is auto-hidden: `currentReservationFrame` is nil
  then, so windows may cover the hidden dock's strip. Intended, untested.
- Carbon reports a combination another app holds as a registration failure;
  that path and its orange message in the pane were never triggered.

### For Stage 2 (edge drag and modifier drag)

- Call `WindowSnapService.shared.perform(action, on: window)`; it already
  handles the dock strip, gap, restore history, overshoot and re-anchoring.
- For a drag preview, `WindowSnapGeometry.targetRect(for:current:area:gap:)`
  with `WindowSnapService.shared.usableArea(of:)` gives the exact rect a drop
  would produce, without moving anything.
- Restore history records the frame before each snap, keyed by `WindowID`;
  a drag-to-snap should go through `perform` so un-snapping by Restore works.
- `WindowRegistry.frontmostWindow()` exists; a drag trigger will need the
  window under the pointer instead.
- Hot keys are released while the pane records (`isRecordingShortcut`); a drag
  monitor should respect `windowSnapEnabled` the same way.

## 2026-10-22, Stage 3b: focus follows mouse, fixed Space order, Win key tap, exclusion editor

Focus follows mouse and fixed Space order are adapted from Vorssaint
(vorssaint/vorssaint-utils, GPL-3.0): `FocusFollowsMouseService`,
`FocusFollowsMouseSupport` and `SpacesOrderHold`. Files:

- `Docky/Services/FocusAndWinTapLogic.swift`: pure logic, Foundation and
  CoreGraphics only, every type `nonisolated` (the Win key detector runs on
  the keyboard tap thread). `HoverDwellState` (the pause timer),
  `HoverWindowScan` and `HoverFocusGate` (which window, and whether to raise
  it), `SpacesOrderPlan.step` (what to write to `mru-spaces` and what to put
  back), `CommandTapDetector` (lone Command tap), `WinKeyTapAction`.
- `Tests/FocusAndWinTap/FocusAndWinTapTests.swift` with
  `scripts/test-focus-and-wintap.sh`: prints `PASS: 66 checks`.
- `Docky/Services/BehaviorExtrasPreferences.swift`: the preferences for all
  three features (see Deviations). Keys: `wharf.focusFollowsMouse.enabled`
  (off), `.delayMilliseconds` (300, clamped 100 to 2000), `.displayUUIDs`
  (empty, so off on every display), `.excludedBundleIDs` (empty);
  `wharf.spacesOrder.fixed` (off), `wharf.spacesOrder.restoreMarker`
  ("absent", "on" or "off", present only while Wharf holds the order);
  `wharf.windowsKeyboardWinTap.action` ("off", "startMenu" or "launchpad",
  default off).
- `Docky/Services/FocusFollowsMouseService.swift`: a global mouse-moved
  monitor installed only while the switch is on, at least one display is
  opted in and Accessibility is granted. A 50 ms check runs only while a
  pause is being timed. On settle it reads the on-screen window list, asks
  AppKit which window would take a click at the point, and raises through
  `WindowRegistry.focus` (the same single-window focus the switcher uses).
  It checks both `AXIsProcessTrusted()` and the cached permission first,
  because `focus` would otherwise put up a permission alert.
- `Docky/Services/SpacesOrderService.swift`: reads and writes `mru-spaces` in
  `com.apple.dock` with CFPreferences and restarts the Dock with
  `forceTerminate`, the way `SystemDockVisibilityService` applies its Dock
  changes. Refuses to write when a management profile forces the value. If
  the user turns rearranging back on in System Settings while Wharf holds it
  off, Wharf lets go and turns its own switch off.
- `WindowsKeyboardService.swift`: the tap mask gains flagsChanged and mouse
  down events, used only to feed `CommandTapDetector`; they always pass
  through untouched. The preference observer now also tracks the exclusion
  list and the Win key choice, so edits reach the tap at once (before, a list
  change needed the mode toggled off and on).
- UI: `FocusFollowsMouseSettingsView.swift` (new pane under Behavior, after
  Windows Keyboard), `BehaviorExtrasSections.swift` (Win key picker and
  exclusion editor appended to the Windows Keyboard pane, Spaces toggle
  appended to Visibility), `BundleIDListEditor.swift` (shared list editor:
  add a running app, choose from Applications, or type a bundle ID; remove
  with the minus button).
- Shared files touched, additive only: `SettingsRootView.swift` (one pane),
  `BehaviorSettingsView.swift` (one line in each of two sections),
  `AppDelegate.swift` (two `start()` lines). `DockyPreferences.swift` is
  untouched.

### Unverified

- Nothing was run against real windows, the real Dock or a real keyboard.
  The build succeeds and the logic checks pass; the following need a hands-on
  check: hover raising on an opted-in display and not on others; no raise
  while a menu is open (detected by any window at the pop-up menu level, 101),
  while dragging, or with a modifier held; the Spaces switch actually freezing
  Space order after the Dock restart and restoring on off (this Mac has no
  `mru-spaces` key today, so turning it off removes the key again); a lone Win
  tap toggling the Start Menu or Launchpad without disturbing Win shortcuts.
- The global mouse monitor does not see movement while Wharf itself is the
  active app (for example with Settings focused). Hovering then does nothing
  until another app is in front. Vorssaint has the same limit.
- The window lookup asks the target app over Accessibility on the main
  thread. A hung app under the pointer could stall Wharf briefly.
- Hovering raises the whole window, as asked. There is no "focus without
  raise" mode (Vorssaint has one through private window server calls).

### Deviations

- **Preferences live in a new store**, `BehaviorExtrasPreferences`, following
  the `PerDisplaySettings` precedent, instead of in `DockyPreferences`. This
  keeps the shared file untouched while sibling branches edit it. The cost:
  "Reset Behavior" and profile snapshots do not cover these settings yet.
  Moving them in later is a mechanical change.
- **No Dock restart journal.** Vorssaint records which Dock process still
  owes a restart so it can tell its own unread write from a change in System
  Settings. Wharf restarts the Dock right after each write instead, as the
  rest of Wharf does.
- **Win key tap is global.** It also works in apps on the exclusion list,
  since the exclusions are about Control translation and a lone Win tap has
  no meaning in a terminal. A tap held longer than 0.8 s is ignored.
- **Launchpad choice** relies on Wharf's Launchpad overlay; if that feature
  is off the tap does nothing (the pane says so).
- **Branch.** Work is on `stage3b-focus-wintap`, branched from
  `feature/vorssaint-parity` at f0bec25, in an isolated worktree.
