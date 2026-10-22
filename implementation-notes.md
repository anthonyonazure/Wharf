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

## 2026-10-22, Stage 2: drag triggers for window snapping

Two ways to snap with the mouse, both inside the existing Window Snapping
pane under a new "Drag Triggers" section, both off by default, both inert
while `windowSnapEnabled` is off. Adapted from Vorssaint's edge snapping
(`WindowGestureSupport.swift`, `WindowLayoutService.swift`). Files:

- `Docky/Services/WindowSnapDragZones.swift`: pure logic (Foundation and
  CoreGraphics only). Pointer to edge action (`edgeHit`), pointer to modifier
  zone (`modifierAction`, `modifierZones`), drag classification (`classify`,
  `startsAtResizeHandle`), the dwell (`WindowSnapDragDwell`), pointer speed
  (`WindowSnapDragPointerTrail`), the modifier set
  (`WindowSnapDragModifiers`) and the macOS tiling check.
- `Docky/Services/WindowSnapDragService.swift`: global NSEvent monitors
  (listen-only), the AX hit test, the drag state machine, the snap on release.
  Started from `WindowSnapService.start()`, so `AppDelegate.swift` is untouched.
- `Docky/Views/WindowSnapDragOverlay.swift`: click-through panel that draws
  the preview rect and, for a modifier drag, the zone map.
- `Docky/Views/SettingsWindow/WindowSnapDragSettingsSection.swift`: the
  section, inserted with one line into `WindowSnappingSettingsView`.
- `WindowRegistry.window(for:pid:)`: maps the AX window under the pointer to
  an `AppWindow`.
- `WindowSnapService.perform(_:on:screen:)`: new optional `screen`, default
  nil keeps the Stage 1 behavior; the hot key path is unchanged.
- Prefs (all `wharf.windowSnapDrag*`): `EdgeEnabled` (off), `ModifierEnabled`
  (off), `HitZone` (12 pt, 2 to 40), `Dwell` (0.15 s, 0 to 1), `Modifiers`
  (Control Option, stored as the NSEvent flag bits). Reset Window Snapping
  also resets these.

How a drag is recognized: on mouse down the AX element under the pointer is
walked up to its window; Wharf's own process, full-screen windows and presses
on a resize border are skipped. After 6 points of travel the window's live
frame is compared with the pointer: only when the window follows the pointer
(same direction, similar distance, size unchanged or restored) is it a window
move. A content drag is dropped after 80 points with the window still, a
resize as soon as an edge stays anchored. This is what makes it "the window
being dragged" by its title bar, without guessing title bar heights.

Edge mapping: left and right edges are halves, top edge maximize, bottom edge
bottom half, corners the quarters. The top edge starts at the bottom of the
menu bar. Corners reach 18 percent along each edge (96 to 180 points across,
80 to 160 points down). An edge shared with another display only counts while
the pointer moves across it slower than 400 points per second, so a window
can still be dragged to the next display. The preview appears after the
dwell; the window snaps on the display the pointer chose.

Modifier zones over the usable area (dock strip and menu bar excluded):
middle band left half, left third, center third, right third, right half
(columns at 20 percent steps); top band top-left quarter, top half,
top-right quarter; bottom band the same for the bottom (rows at 25 and 75
percent). The overlay shows all zones, the lit one, and the exact target.

Run the zone checks with `scripts/test-snap-zones.sh` (101 checks).

### Deviations

- **Listen-only, so macOS tiling is warned about, not suppressed.** Vorssaint
  uses an active event tap to nudge the pointer off the top row so the
  system's top-edge window overview does not open. Wharf only observes
  events, as the brief asked. When macOS's own edge tiling is on, the pane
  shows an orange line and a button to Desktop & Dock settings.
- **No AX messaging timeout.** Setting one on the system-wide element would
  shorten every AX call Wharf makes, not just the drag hit test, so it is left
  at the default. A hung app could stall a click for that default timeout
  while a drag trigger is on.
- **Restore after a drag snap returns to the drop spot,** at the window's
  pre-drag size, not to where the drag started: `perform` records the frame
  at release.
- **Modifiers can be pressed after the drag starts.** Holding Control before
  the press turns it into a right click in many apps, so the window may never
  move. The pane says so.
- **The modifier zone grid is Wharf's own design.** Vorssaint has no
  modifier zone overlay; its edge zones are configurable per part, which was
  not ported.
- **Escape cancels a pending snap** (not in the brief); it needs the global
  key monitor, which is why `.keyDown` is in the monitor mask.
- **Not ported:** Vorssaint's per-edge zone editor, split edges, and its
  top-edge pointer nudge.

### Unverified

- Nothing was run against a real window, for the same reason as Stage 1: a
  second Wharf would put a second set of docks on screen. No drag, preview,
  zone map or snap has been seen.
- Whether title bar drags of other apps deliver `leftMouseDragged` to a
  global NSEvent monitor on this macOS (Rectangle relies on it).
- Whether adding `.keyDown` to the global mask raises an Input Monitoring
  prompt when a switch is turned on.
- The overlay panel level (`.floating`) against the dragged window and
  against Wharf's dock.
- The per-click cost of the AX hit test while a switch is on.
- Apps that draw their own title bar (Chrome tabs, Electron) were not tried;
  the follow-the-pointer test should cover them.
- The macOS tiling warning reads `com.apple.WindowManager` defaults; whether
  those keys are still the ones macOS 27 uses was not checked.
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
  `scripts/test-focus-and-wintap.sh`: prints `PASS: 67 checks`.
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

### Read-only probe

A scratch script (no windows touched) confirmed two things the hover path
rests on: `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` returns
another app's window (a Brave window on the second display), and the y flip
against the main screen lines up with `kCGWindowBounds`. It also showed the
pointer itself listed as a small Window Server window at the cursor level on
top of everything, so the fallback path (used when AppKit has no answer) now
looks through it.

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
## 2026-10-22, Stage 3a: Window Behavior (green button, quit on close, quit protection)

Three features in one new Settings pane, Features > Window Behavior, each with
its own switch, all off by default. Adapted from Vorssaint
(vorssaint/vorssaint-utils, GPL-3.0): WindowMaximizer, WindowServerTrafficLightHitTest
and WindowServerSupport, WindowMaximizerSupport, AutoQuitService, and
QuitProtectionSupport and QuitProtectionService. Files:

- `Docky/Services/WindowBehaviorLogic.swift`: pure logic (Foundation and
  CoreGraphics only). Bundle id list matching, the window server scan for a
  green button under the pointer, the green button modifier rules, the quit on
  close decision, and the Command-Q and Command-W state machine
  (`QuitGuardStateMachine`) with its per-app policy.
- `Docky/Services/WindowBehaviorPreferences.swift`: its own `@Observable`
  settings object under `wharf.windowBehavior.*` in the standard defaults, so
  `DockyPreferences.swift` only gained one line (the global reset calls
  `WindowBehaviorPreferences.shared.resetToDefaults()`).
- `Docky/Services/GreenButtonMaximizeService.swift`,
  `Docky/Services/QuitOnCloseService.swift`,
  `Docky/Services/QuitGuardService.swift` (with its HUD), and
  `Docky/Services/WindowBehaviorService.swift`, which starts all three from one
  line in `AppDelegate`.
- `Docky/Views/SettingsWindow/WindowBehaviorSettingsView.swift`: the pane.
- Checks: `scripts/test-window-behavior.sh` builds the logic with
  `Tests/WindowBehavior/WindowBehaviorLogicTests.swift` and prints
  `PASS: 85 checks`.

How each works:

- **Green button.** An event tap looks at left clicks. A cheap window server
  scan first decides whether the click could be on a green button at all;
  only then does Accessibility confirm it is the zoom (or full screen) button.
  A plain click maximizes through `WindowSnapService.perform(.maximize, on:)`,
  so it lands on the same rectangle as the Maximize shortcut (menu bar, macOS
  Dock and Wharf dock excluded, snap gap kept). A second click on a window
  already at that rectangle runs Restore. Option-click sets the window's
  full screen attribute. Command, Control or Shift clicks, apps on the
  exception list, and windows already in full screen are left to macOS.
- **Quit on close.** Watches `WindowRegistry.windows` for apps on the list.
  When a listed app that has shown a window drops to none, it looks again at
  0.35, 0.9 and 1.8 seconds, and only asks the app to quit
  (`NSRunningApplication.terminate()`, never force) when every look agrees:
  regular app, not Wharf, not hidden, no window in Accessibility (minimized
  ones count as windows) and no normal window in the window server's full list.
- **Quit and close protection.** A key tap reads only Command key presses
  (plain typing returns at once). For the frontmost app it resolves the mode
  (per-app override, else the default; a key not protected is off), and the
  state machine says whether to pass, hold back, or confirm. Confirming
  Command-Q sends the app a normal quit request; confirming Command-W replays a
  marked Command-W press that the tap lets through. Escape or letting go of
  Command cancels. A small panel near the bottom of the screen says what to do,
  with a progress bar while holding.

### Deviations

- **The green button tap swallows events; it is not listen-only.** A
  listen-only tap cannot stop the click reaching the app, so the window would
  start entering full screen while Wharf maximized it. The tap passes every
  event except the press and release of a confirmed green button click.
- **Option gives full screen by setting the window's full screen attribute.**
  On current macOS an Option-click on the green button natively zooms rather
  than entering full screen, so passing it through would not do what the brief
  asked.
- **Quit on close leans toward keeping apps open.** Without Vorssaint's private
  Space APIs, a window hidden on close and a window on another Space look the
  same, so both count as "still has a window". Apps that hide their window
  instead of closing it (some chat and music apps) will therefore not quit.
- **Command-Q protection quits through a quit request, not by replaying the
  key.** Same as Vorssaint; Command-W is replayed. Vorssaint's special cases
  for remote desktop and virtual machine apps (where Command-Q should reach the
  remote computer) and its app switcher handling are not ported.
- **Key matching uses the typed character, then the US key position.**
  Vorssaint also consults the layout's Command table for non-Latin layouts;
  on those layouts protection may not trigger.
- **One mode for both shortcuts.** Command-Q and Command-W each have an on
  switch but share the default mode and the per-app overrides; Vorssaint keeps
  separate settings per shortcut.

### Unverified

- None of the three features was exercised at runtime: that needs real clicks
  and key presses on the user's own windows and apps. The build succeeds and
  the pure logic passes its checks.
- A read-only probe of 17 running apps found the zoom button inside the
  window server box for 16; the exception (Zen) had its button above the
  window frame, so its clicks simply pass through to the app.
- Order of the quit protection tap against Windows Keyboard Mode's tap (which
  turns Control-W into Command-W): both insert at the head of the session, so
  which runs first depends on which was created first. If Windows Keyboard Mode
  runs second, a Control-W it rewrites is not protected.
- Restore after a green button maximize relies on WindowSnapService's history;
  a window maximized by other means is left as is on the second click.

Follow-up fixes in the same stage: quit on close no longer re-arms its checks
after a look finds a window (that made apps which hide their window on close
get re-checked on every window change anywhere), and quit protection steps
aside while Wharf's own window switcher is open, since the switcher uses W
under the Command chord to close the selected window. The green button match
uses `AppWindow.cgWindowID`, which WindowRegistry fills from
`_AXUIElementGetWindow`, the same number the window server scan returns.
Unverified: after a declined "Save changes?" prompt, closing that sheet could
count as another last-window close and ask the app to quit again; WindowRegistry
only filters floating subroles, not dialogs.
## 2026-10-22, Stage 4a: Command Bar

A floating search field opened by a global shortcut, modeled on Vorssaint's
command bar (vorssaint/vorssaint-utils, GPL-3.0). It searches installed and
running apps, open windows, files (Spotlight), the menu commands of the app
in front, and window snap layouts, and it answers arithmetic and unit
conversions. Files:

- `Docky/Services/CommandBarCore.swift`: pure logic, Foundation only. The
  calculator (`CommandBarCalculator`), unit conversion (`CommandBarUnits`),
  number formatting, ranking (`CommandBarRanking`) and the bounded recency
  store (`CommandBarRecency`, 200 entries).
- `Docky/Services/CommandBarPreferences.swift`: its own `@Observable` store
  with Keys and DefaultValues, every key prefixed `wharf.commandBar.`:
  `enabled` (default off), `shortcut` (default Option-Space),
  `disabledSources` (stored as the off set, so new sources start on),
  `maxResults` (default 8, 3 to 20), `recency`.
- `Docky/Services/CommandBarMenus.swift`: the Accessibility menu bar walk,
  adapted from Vorssaint. Background queue, depth 4, 400 items, 0.35 s AX
  timeout on the app element, every CF value type checked before casting.
  Skips the Apple, Window and Help menus.
- `Docky/Services/CommandBarService.swift`: gathers candidates, ranks, runs
  the choice, owns the Carbon hot key (signature `CMDB`) and
  `conflictMessage(for:)`.
- `Docky/Views/MainWindow/CommandBarWindowController.swift`: the panel. Same
  recipe as the Start Menu panel (borderless, non-activating, can become key,
  level above the menu bar), centered near the top of the screen under the
  pointer, styled with `dockyGlass`, the dock tint and 12 point corners.
- `Docky/Views/SettingsWindow/CommandBarSettingsView.swift`: the pane, under
  Features as "Command Bar".
- Shared files, additive only: `SettingsRootView.swift` (one case in each
  switch and the Features list), `AppDelegate.swift` (one start line),
  `WindowSnapService.swift` (the snap pane now refuses the Command Bar's
  shortcut when the bar is on), `README.md` (credit line).

How it behaves:

- Keyboard: Up and Down move, Return runs, Tab opens the selected row's
  quick actions (apps: Open or Switch To, Show in Finder, Hide, Quit;
  windows: Bring to Front, Minimize, Close, Left Half, Right Half, Maximize;
  files: Open, Show in Finder, Copy Path; sums: Copy Result, Copy Plain
  Number), Escape closes the action list and then the bar. A click outside,
  or the panel losing key status, closes it.
- The app in front and its focused window are captured when the bar opens,
  so menu commands and snaps land there. The bar never activates Wharf.
- Ranking: exact title, then prefix (shorter titles first), word prefix,
  all query words as word prefixes ("half left"), initials ("vsc"),
  substring, letters in order. Plus up to 200 points of history (frequency
  and freshness) and a small tie breaker (apps, then windows, then menu
  items). An empty field shows recently chosen items.
- Files: `NSMetadataQuery`, `NSMetadataQueryLocalComputerScope` only,
  display name contains the text (passed as a predicate argument), app
  bundles excluded, newest used first, debounced 250 ms, 2 or more
  characters, stopped after the first gather, at most "max results" rows.
- Calculator: + - * / ^ (and **, the Unicode minus, times and divide),
  postfix percent, brackets, pi, e, sqrt abs sin cos tan asin acos atan ln
  log exp floor ceil round. Input over 200 characters, 200 tokens or 32
  levels of nesting is refused; every intermediate value must be finite;
  division by zero is refused. A bare number is not a calculation.
- Units: temperature, length, mass, data (decimal and binary), duration,
  volume, speed and area, as "number unit to unit" (also in, into, as, ->).
  Units of different families never meet, since Foundation traps on that.

### How to run the checks

    scripts/test-command-bar.sh

Builds `CommandBarCore.swift` and `WindowSnapGeometry.swift` with
`Tests/CommandBar/CommandBarCoreTests.swift` and prints `PASS: 273 checks`.
Includes hostile input (1/0, 0/0, 9^9^9^9, 2^999999, 1e999, 5000 open
brackets, 1000 nested sqrt, 10,000 repeats of 1+, a 10,000 digit number,
NUL bytes, emoji, Arabic digits) each timed under 50 ms, 10,000 random
expressions, and a watchdog thread that fails the run after 20 seconds.

### Deviations

- **Separate preferences store.** Settings live in `CommandBarPreferences`,
  not `DockyPreferences`, to keep the shared file untouched. So the global
  "reset everything" in `DockyPreferences.resetToDefaults()` does not reset
  the Command Bar; the pane has its own Reset button.
- **Default shortcut is Option-Space,** stored but only registered once the
  bar is switched on (default off). Nothing in Wharf uses it. Raycast and
  Alfred often do; then the pane shows the orange "another app already uses
  this shortcut" line.
- **Conflicts refused:** Start Menu's fixed Control-Option-S (Stage 1's
  list misses it, so a snap shortcut could still collide with it), Launchpad,
  the Window Switcher and its Shift reverse, the Windows snip, every snap
  shortcut, and Control keys that Windows Keyboard Mode rewrites. The
  Launchpad and Window Switcher recorders do not check against the Command
  Bar in return.
- **Numbers use a period for decimals in every locale.** A comma is only
  accepted as a thousands separator (exactly three digits after it);
  "1,5" is refused rather than read as 15. Results are displayed in the
  Mac's own number format.
- **No clipboard history or snippets** (Wharf has neither), no web search,
  emoji, dates, system settings or scripts from Vorssaint's bar.
- **Window rows are not remembered** in history, since window identities do
  not survive a relaunch. File rows are not remembered either, so no file
  paths are stored.
- **Installed apps come from Launchpad's scan**, which runs in the
  background at launch. Opened in the first second after launch, the bar may
  list only running apps.

### Unverified

- The Debug build was not launched, for the same reason as Stage 1 (a second
  Wharf would add docks and register shortcuts system wide). So the panel,
  its focus, the hot key, the key handling, the settings pane and every
  action were not seen working.
- Whether a non-activating panel takes key focus for typing when Wharf is in
  the background is assumed from the Start Menu, which uses the same recipe.
- The menu walk and pressing a menu item were not run against a real app.
- Spotlight speed and result quality with a broad "contains" search on the
  whole local disk were not measured; a short query may take a moment.
- The Option-Space registration failure path was not triggered.

## 2026-10-22, Review fixes: window snapping (Codex and Gemini reviews)

Two independent adversarial reviews (Codex, Gemini) of the snap engine.
Every claim below was checked against the code before fixing. Geometry fixes
each have a regression check in `Tests/WindowSnap/WindowSnapGeometryTests.swift`
built from the reviewers' own numbers; the old code was run against the new
checks and failed them (2 point gap at x = 0, minimum-size window left at
x = 2000 past the destination edge), the new code passes. Totals: geometry
251 checks, zones 101 checks, Debug build succeeds.

1. Restore to an unplugged display (both reviewers). New
   `WindowSnapGeometry.restoreTarget`: a remembered frame that still lies
   wholly on connected displays comes back exactly; one that hangs off every
   display is shrunk to fit and pulled into the usable area of the display it
   overlaps most, or the nearest one. Codex case (2000,100,800,600) with only
   the 1440 x 900 primary now lands at (640,100,800,600).
2. Restore is transactional. `WindowSnapHistory.peekPrevious` reads the entry
   without removing it; the service applies it, reads the live frame back, and
   pops only when the window is within 8 points of the target. A failed
   Restore keeps its entry. When the clamped target equals where the window
   already is, the entry is dropped so Restore cannot stall on it.
3. Position taken, size refused (fixed-size windows). `apply` no longer stops
   when the AX resize reports failure: it reads the actual frame, gives up only
   if the window did not move at all, and otherwise runs the re-anchoring. The
   Codex case (800 x 600 fixed window, right half of 1000 x 800) re-anchors to
   (200,0,800,600). `WindowRegistry.resize` is unchanged for its other callers.
4. Display moves with a minimum size. `anchoredRect` for Next and Previous
   Display now keeps the top-left corner at the size the app insisted on and
   clamps it into the destination. Codex case: (2000,120,400,240) with an
   800 point minimum width becomes (1600,120,800,240).
5. Overshoot retry direction (Gemini). New
   `WindowSnapGeometry.overshootApproach` works in AppKit space and nudges
   away from the edge a Wharf dock trimmed (right for a left dock, down for a
   top dock); right, bottom and no Wharf dock keep the original left and up
   nudge, so the case that worked is unchanged.
6. Untracked focused window. `WindowRegistry.frontmostWindow` returns nil when
   AX names a focused window the registry does not track (floating tool
   windows), instead of snapping another window of the same app. The fallback
   to the app's latest window stays only for apps that report no focused
   window at all.
7. Shortcut conflicts. Start Menu's fixed Control Option S is now a static
   (`StartMenuService.shortcut`) that both its registration and the snap
   conflict check read. Launchpad and the Window Switcher pair are reserved
   only while their features are on (both unregister their keys when off).
8. The queued hot key handler re-checks `windowSnapEnabled` and
   `isRecordingShortcut` immediately before acting.
9. Rounding (Codex). `roundedEdges` now rounds halves up (toward +infinity)
   instead of away from zero. The rule is translation invariant, so two edges
   an integer gap apart stay exactly that far apart wherever the shared
   boundary falls. Checked for halves, thirds and quarters, horizontal and
   vertical, gaps 1 and 2, on areas with negative, zero and positive
   boundaries.

### Deviations

- Fix 9 changes the shared rounding rule rather than computing each shared
  boundary once per action. It gives the same guarantee (exact integer gap at
  every boundary) with one small change instead of reworking every tile
  formula; it differs from the old rounding only for values ending in exactly
  .5 below zero.
- Fix 10 (Gemini: frame read right after a set is racy) disproved:
  `liveFrame` is a direct synchronous `AXUIElementCopyAttributeValue` on the
  live element, and the set before it is a synchronous round trip the app
  answers after handling it. No settle poll added; a comment in `apply` says so.
- Restore is still excluded from size re-anchoring: its target is the
  window's own earlier size, and re-anchoring could move a window the user
  had deliberately placed across a screen edge.
- Codex's "revalidate conflicts when an owner is enabled again" is out of
  scope: the settings pane only checks conflicts while recording, and there is
  no live conflict display to refresh. If a user later turns Launchpad or the
  switcher back on with a combination a snap action took meanwhile, the later
  registration (Launchpad or the switcher, since snapping registered first)
  is expected to fail with no warning. Not tested.
- Restore history still stores frames only, not a display identity (Codex
  suggested both). The clamp covers the unplugged case without it.
- Gemini findings not on the fix list, seen and not addressed here: hot key
  registration off the main thread (#4), one corrupt stored shortcut dropping
  all of them (#5, flagged unverified by Gemini itself), and Control Command
  combinations in Windows Keyboard Mode (#6).

### Unverified

- None of the AX paths (partial size failure, restore verification, retry
  nudge, floating tool windows) were driven against real windows; they are
  checked by reading and by the geometry checks only.
- Whether a fixed-size app reports the size failure through
  `AXUIElementSetAttributeValue` (as Codex assumed) or silently keeps its size
  was not observed; both paths now reach the re-anchoring.
- The retry nudge only knows about Wharf's own dock. With the macOS Dock on
  the left and no Wharf dock there, the nudge is still the old left and up.
- A restore that had to shrink an oversized frame keeps its entry if the app
  then refuses the smaller size, so that window's Restore keeps reporting
  failure until it is snapped again. Harmless, but new behavior.
## 2026-10-22, Stage 4b: preview card actions and layouts from the dock

### What was built

- **Preview Actions.** Hovering a window's card in a tile's hover preview
  shows a small row of round buttons in its top right corner (in the list
  layout, at the right end of the row): Snap, Minimize and Close. Snap opens
  a menu with Left Half, Right Half, Maximize and, with more than one
  display, Next Display. Each button acts on that card's window through
  `WindowSnapService.perform(_:on:)`, which already took a window, so no new
  overload was needed. A minimized window's card shows Restore instead of
  Snap and Minimize. Close and Minimize drop the card and keep the preview
  open; Snap and Restore close the preview and bring the window forward.
  The existing "more" button, click-to-focus, hover delay and grace dismiss
  are unchanged; the Snap menu uses the same menu plumbing as the "more"
  button, which holds the preview open while a menu is up.
- **Settings.** Window Management, Window Preview section, a new "Preview
  Actions" group: Close Button, Minimize Button, Snap Menu, each on by
  default, and "Layouts in Dock Menus", on by default. The orange
  Accessibility line shows when any button is on and the permission is
  missing. Keys use the `wharf.previewActions.` prefix in a new
  `PreviewActionsPreferences`; DockyPreferences was not touched.
- **Layouts from the dock.** A "Layouts" submenu in the dock's background
  menu (the divider's right-click menu), in the right-click menu of Wharf's
  own tiles (Start, Launchpad, spacers and other Wharf-pinned tiles) and in
  the Wharf menu bar item. It lists saved layouts for one-click Restore, then
  "Save Current Layout..." (asks for a name, suggests "Layout N", confirms
  before replacing a layout of the same name), then "Undo Last Restore" when
  there is one. Holding Option restores and also opens missing apps through
  `launchAndRestore`, the same path the Layouts widget uses. With the switch
  off, the menu bar item goes back to its old flat list.
- **Pure logic** in `Docky/Services/PreviewActionsLogic.swift`, checked by
  `scripts/test-preview-actions.sh` (32 checks): which buttons show, what
  happens to a card afterward, snap choices per display count, the Layouts
  rows, the suggested name, name trimming and the replace check.

### Deviations

- **Defaults are on**, against the usual default-off rule, because the brief
  asked for close, minimize and the snap menu on by default. Each only acts
  on the window the user points at. The Layouts submenu is also on, since it
  only adds a menu entry.
- **Minimize always removes the card**, even when previews list minimized
  windows. The card's dimmed minimized look is set when the preview opens and
  would not refresh, so a live-looking card for a window that just left the
  screen would read as a failed click. It comes back dimmed on the next hover.
- **The launch-missing-apps variant is behind Option**, not a second row per
  layout. In the menu bar item it is a standard Option alternate. In the dock
  menus the titles change if Option is already held when the Layouts submenu
  opens, and Option held at the moment of the click also counts.
- **Restore with launch uses `launchAndRestore`** (polls for the new windows),
  as the Layouts widget does, rather than the fixed 3 second delay in the
  Settings pane and the URL scheme.
- **"No Saved Layouts" in the dock menus is a clickable no-op**: the shared
  `ContextAction` type has no disabled row. The menu bar version is disabled.
- **The dock has no separate background menu**; the divider's menu is the
  dock-wide one (hiding, magnification, position, settings), so that is where
  the submenu went, next to Edit Dock.

### Unverified

- The Debug build was not launched, same reason as earlier stages (a second
  Wharf would add docks on the real desktop). So the buttons, their hover
  reveal, the Snap menu holding the preview open, the save prompt taking
  typing, and the menus were not seen working.
- Assumed, not observed: a Button inside the card wins the click over the
  card's tap-to-focus gesture (standard SwiftUI behavior), and `.focusable(false)`
  plus the never-key panel keep keyboard input with the user's app.
- The Option alternate rows in the menu bar Layouts submenu follow the
  documented NSMenu pattern (primary with no modifier, alternate with Option)
  but were not seen swapping.
- The "Layouts in Dock Menus" switch sits in the new Preview Actions group so
  LayoutsSettingsView (a shared file) stayed untouched; the merger may move it
  to the Layouts pane.
- WharfTests is hosted inside Wharf.app, so it was compiled
  (`build-for-testing` succeeded) but not run. All six standalone check
  scripts pass.
- New `String(localized:)` titles ("Layouts", "Save Current Layout...",
  "Undo Last Restore", "No Saved Layouts") were not added to
  Localizable.xcstrings by hand; Xcode extracts them on the next build in the
  IDE, and Spanish has no translation yet.
- The README Credits section already repeats the snapping paragraph three
  times from earlier stage merges; left as is, flagged for cleanup.
## 2026-10-22, Stage 5: multi-row docks and per-display settings

### Multi-row docks

The row arithmetic already existed, but two things still clipped extra rows:

- The dock window never re-measured when the **Rows** stepper changed. The
  tiles redrew in several rows while the panel kept its one-row frame until
  something unrelated (a tile change, a display change) resized it. The frame
  now watches the row count.
- The window was measured by wrapping the whole tile list into rows, section
  dividers included, while the view wraps each section (pinned, running,
  trailing) on its own. The panel asked for a different shape than the rows
  drawn. Both now go through `Docky/Services/DockRowLayout.swift`, which is
  Foundation only. The magnification hover center uses the same file, so a
  tile in row two no longer measures as though it followed all of row one.

The reservation frame (`MainWindow.currentReservationFrame`, used by
`WindowReservationService` and `WindowSnapService`) is the window frame
itself, so it grows with the rows with no change of its own. A bottom dock
gets taller, and a left or right dock wider, by one tile plus one gap per
extra row. `scripts/test-dock-rows.sh` checks that number (20 checks).

### Per-display settings

Each display can override **edge, tile size and autohide** in **Settings,
Behavior, Placement, Displays**. Each connected display gets a row with a
"Use global settings" toggle; turning it off copies the current global values
in, so nothing moves until one is changed.

- Storage is the existing `wharf.perDisplayOverrides` store, keyed by display
  UUID, with one new optional field, `autohide`. Entries saved before this
  stage still load. Nothing deletes an entry when a display is unplugged, so
  it comes back on reconnect; a display that is not connected is just not
  listed and its entry is never asked for.
- Rules live in `Docky/Services/PerScreenResolution.swift` (Foundation only):
  override wins, otherwise global. An unknown edge name, a non-numeric or
  non-finite size, or a non-boolean autohide falls back for that field alone;
  sizes are clamped to the slider's 16 to 128 pt. Stored data is now read
  entry by entry and field by field, so one corrupt entry no longer wipes
  every display's overrides (before, the whole store decoded or nothing did).
  `scripts/test-perscreen.sh` covers partial, corrupt, garbage, old-format
  and vanished-display cases (44 checks).
- `Docky/Services/DockContext+PerScreen.swift` is the single seam: the window
  frame, the chrome, the tiles, folders, dividers and the profile switcher all
  ask the dock's context for its edge and tile size, so a left override no
  longer moves the window while the tiles still lay out in a horizontal strip.
- Global settings are unchanged and still move every display that has no
  override.

### How to run the checks

`scripts/test-dock-rows.sh`, `scripts/test-perscreen.sh`, the build command,
and the WharfTests command from HANDOFF.md (1,988 tests, 0 failures, 7 skipped
as before). The test run needs default signing; with
`CODE_SIGN_IDENTITY=-` the build fails on an embedded binary signature check.

### Deviations

- **Theme per screen and contents per screen are skipped**, as asked. The
  store has a theme field already, but nothing reads it; every dock still wears
  the global theme and shows the same tiles.
- **Overrides apply only when Display is All Displays.** The single dock modes
  have no bound display, so they always use the global values. The Displays
  section says so in orange when another mode is selected.
- **Pop-overs still use the global edge**: the dock editor overlay and hint,
  profile switcher window, Start Menu, widget expansion and settings panels,
  and the folder fan's size. On a display whose edge differs from the global
  one, these can open toward the global edge.
- The global Window Position picker has no Top choice, so the per-display
  picker has none either. The row code handles all four edges.
- Dragging the per-display size slider saves on every step, like the global
  slider does.

### Unverified

- Nothing was seen on screen. The running copy is the installed build, and
  launching the Debug build beside it would add a second set of docks, so no
  multi-row dock, override or Displays section was looked at. The multi-row
  fix rests on the measured geometry in the check script, not on a screenshot.
- Snapping and Resize Windows clearing a multi-row dock follow from the frame
  growing; they were not run against real windows.
- Unplugging and reconnecting a display was not done; persistence across it is
  shown by the stored-value checks, not by hardware.
- The first frame of a bound dock with an autohide override (the window is
  built before it knows its display, then settles) was not watched for a
  brief flash.
## 2026-10-22, Stage 3b review fixes

Two independent adversarial reviews of Stage 3b (Codex and Gemini) were
checked claim by claim against the code. Every claim on the consolidated
list was confirmed by reading the code; none was disproved. Fixes:

1. **Hover focus no longer freezes Wharf.** The Accessibility calls
   (which window the front app has focused, and finding the target
   window's element) run one at a time on a worker queue with a 0.25 s
   timeout per message and at most 64 windows read. The registry's cached
   snapshot is used first, at no Accessibility cost. A lookup answering
   after 1 s is dropped. Right before raising, the main thread reads
   everything fresh (`HoverCommitCheck`): feature still on and permitted,
   pointer still where it rested, the same window still under it, no menu
   open, no button or modifier held, evaluation not stale.
2. **Moving into Wharf cancels a pending hover.** A local event monitor
   resets the pending rest; the live pointer check covers Wharf windows
   that do not report mouse moves.
3. **Fixed Space order is crash safe.** A journal (what to put back plus a
   phase: pendingHold, held, pendingRelease) is saved, flushed and read
   back before the Dock preference is touched. The Dock write is flushed
   and read back; the journal is cleared only after a restore reads back
   correctly. A pending Dock restart is recorded first and cleared when a
   Dock under a new process ID appears (or its launch notification
   arrives); otherwise retried up to 3 times per launch, then logged. A
   restart still pending at launch is retried. Markers from the earlier
   build (no phase) are read as held.
4. **Changes made in System Settings are noticed while Wharf runs.** The
   preference is checked again when System Settings is left or quit and
   when the Dock starts. A held setting turned back on there makes Wharf
   let go and the switch turn off.
5. **Win key tap:** respects the exclusion list (checked on every event,
   so a press begun elsewhere cannot finish in an excluded app), and is
   cancelled by a scroll wheel event (now in the tap mask) or by any mouse
   button held at Command press or release. Command+Q and other chords
   still cancel.
6. **Win+Shift+S works in excluded apps.** The two reviews disagreed here
   (Codex saw the old behavior as intended for remote desktop apps); the
   consolidated list was followed. The Excluded Apps footer now says so.
7. **Bundle IDs ignore case** in both exclusion lists: adding, duplicate
   checks, the running apps menu and run time matching. The spelling first
   added is shown. The Focus Follows Mouse list drops case duplicates on
   load. The editor list is a LazyVStack.
8. **Reset Behavior and the full reset include these features.** The
   Space order switch goes off first and the journal is left for the
   service's normal release, which restores the Dock preference.
9. **The clamped hover delay is saved,** and an out of range or malformed
   stored value is rewritten at launch.
10. **Keyboard tap teardown race fixed.** The tap, its runloop source and
    runloop are behind the existing lock. Teardown takes them out under
    the lock and tears down after releasing it; the tap thread's re-enable
    uses a reference copied under the lock, so it can never touch a freed
    tap and never waits on teardown.

`scripts/test-focus-and-wintap.sh` now prints `PASS: 109 checks`, with new
checks for every journal phase, case-insensitive bundle IDs (including the
hover gate), the stored delay, the commit check, and tap cancel on scroll,
on a held mouse button and on Command+Q. All other check scripts still
pass; the Debug build succeeds.

### Deviations

- **No polling for external Space order changes.** Rechecks happen on
  System Settings deactivate or quit and on Dock launch. A change made by
  `defaults write` in Terminal is noticed only at the next of those or at
  the next launch. Residual gap: turning rearranging on and then off again
  inside System Settings, without leaving it, is never seen as "on", so a
  later release still puts back the value from before Wharf held it.
- **Journal key order.** The phase is written before the marker and
  removed after it, so a crash between the two never leaves a marker that
  reads as held. At launch a Dock restart left pending by the last run is
  retried only if `apply` did not just restart the Dock itself.
- **Held mouse is sampled from the hardware state** at Command press and
  release (`CGEventSource.buttonState`) rather than tracked from mouse up
  events, so a button release the tap never saw cannot leave it stuck.
- **Own window lookup instead of `WindowRegistry.liveWindows`.** The
  registry is main actor isolated, so the worker reads the app's windows
  itself and hands the element back. `focus()` still runs on the main
  thread; its Accessibility calls use the element's 0.25 s timeout.
- **Failed hold turns the switch off.** If the journal cannot be saved,
  the Dock is not touched; if the Dock write does not read back, the
  switch goes off and the normal step undoes whatever landed.
- **Not addressed:** Gemini's guess that these settings might be shadowed
  for an app group (no app group is used; labeled unverified by Gemini),
  and Codex's Mission Control and other event tap notes (flagged by Codex
  as unverified risks, not failures).

### Unverified

- The app was not launched, so none of this was seen working at run time:
  hover raising, the local monitor, the Dock restart and its confirmation,
  the System Settings recheck, and the Win tap with scroll or a drag.
- Crash windows in the Space order journal were reasoned through and unit
  checked, not fault injected.
- Whether `CFPreferencesAppSynchronize` reports failures in practice, and
  whether the Dock always comes back under a new process ID within 5 s.
## 2026-10-22, Stage 3a review fixes

Two independent adversarial reviews (Codex and Gemini) of Stage 3a found
defects in the code that swallows input and can quit apps. Every claim was
checked against the code before fixing. The rule applied throughout: when
in doubt, do not swallow input and do not quit anything.

### What changed

- **Taps decide from cached answers only.** Quit protection keeps the app in
  front and the policy as cached snapshots (refreshed from the activation
  notification and the preference observer); with no cached app it protects
  nothing. The HUD is shown and hidden off the tap. The green button tap no
  longer asks Accessibility anything: a listen-only pointer monitor looks up
  each window's green button ahead of time and caches it per window id; a
  press is held back only when the cache matches the exact window in front
  at that point, unmoved, with the point inside the real button frame (no
  inflated frame). Otherwise the click goes to the app and the lookup runs
  for next time.
- **Confirmations are bound to their target.** The app is captured at the
  first press, and for Close the focused window too (read just after the
  tap, never in it). Switching apps cancels the wait. Right before acting,
  the app must still be running and in front, and for Close the focused
  window must still be the captured one. Quit is a normal terminate request
  only; if it is refused nothing else is tried. Close sends Command-W to the
  captured app alone (postToPid), so a browser still closes a tab. The old
  fallback that posted a global Command-Q or Command-W is gone; a failure
  shows a short HUD note instead.
- **Press twice needs the same app twice.** A second press in another app
  starts that app's own sequence. The old test that expected the first app
  to be quit was reversed.
- **Held keys are owned by physical key code** until their release, apart
  from the pending protection, so a cancel, an expiry, a Command release or
  Escape can no longer let autorepeats or the release through. Escape's own
  release is now swallowed. Releases match by key code, never by the
  character the current input source types.
- **Quit on close counts everything and doubts loudly.** Window counts come
  from an unfiltered Accessibility window list and from window server levels
  0 to 19 (floating panels, modal dialogs); a failed read counts as windows
  present. A window seen again, or the app being activated, stops pending
  looks. After a quit request, no second one is sent until the app shows a
  standard window again (so cancelling a save prompt does not loop).
- **One deterministic keyboard order.** The quit protection tap is now tail
  appended on the session tap, after every head inserted tap, so Windows
  keyboard translation always runs first and a translated Control-W is
  protected. Head inserted taps run in reverse install order, which is why
  the old result depended on which switch was turned on last; with the tail
  placement both toggle orders reduce to the same chain. This cannot be unit
  tested; scripts/test-window-behavior.sh checks the placement in the source.
- **Remote screens and virtual machines pass through by default**
  (Windows App and Microsoft Remote Desktop, VMware Fusion and Horizon,
  Parallels, UTM, Citrix Viewer, Jump Desktop, VirtualBox, Screen Sharing and
  similar, list adapted from Vorssaint). An explicit per-app mode still wins.
- **Green button pairs.** GreenButtonPairTracker keeps a held back press and
  its release together, and swallows drags in between. Any interruption (tap
  disabled, tap removed, permission lost) forgets the held press so its
  release passes and no stale action runs; a press the app saw never has its
  release swallowed. At action time Accessibility must find the zoom or full
  screen button itself (or a child of it) at the click point, else the click
  is dropped. A click on a window of a background app focuses that window.
  In a right-to-left language the button area is mirrored to the top right.
- **Hold-to-tile decision.** Swallowing the press would hide the macOS tiling
  menu that opens on a held green button. If the button is still down after
  0.45 s, Wharf hands the original press back to the app (marked so its own
  tap lets it by) and lets the release through, so the app runs its own hold
  from there. A quick click maximizes as before. The menu opens about half a
  second later than without Wharf; the hover tiling menu is untouched.
- **Secure Input.** The Window Behavior pane shows an orange note while
  Secure Event Input is on, since macOS then hides key presses from every
  tap and protection is paused.
- New checks: target binding, app switch cancel, physical key ownership,
  Escape release, double press target, quit-on-close episode record, failed
  reads, panel levels, RTL hit area, remote pass-through, green button pairs,
  plus source guards for the global post and the tap placement. 135 logic
  checks (was 85).

### Deviations

- **Taps still run on the main run loop.** Moving them to their own thread
  would remove the remaining dependency on a busy main thread, but under the
  project's MainActor default isolation it is the likeliest way to add a data
  race. Instead all slow work left the callbacks: no Accessibility, no HUD,
  no app lookups. The green button lookup ahead of a click runs on its own
  queue, so a hung app never asks the main thread (where both taps run) to
  wait; every Accessibility element it touches has a 0.35 s timeout set
  before the first question. The green button callback still reads the
  window server list once per press, which is not an app and does not hang
  the way an unresponsive app's Accessibility does. Two Accessibility steps
  still run on the main thread, both bounded by timeouts and never inside a
  tap: the check right before a maximize, and reading the focused window for
  a protected Close.
- **A change of focused window inside the same app is not watched.** It is
  caught by the check right before acting (the captured window must still be
  focused), which is where it matters.
- **The first click on a window the pointer never rested over is native.**
  The hover lookup usually finishes in a few milliseconds, but a pointer that
  jumps onto the button and clicks at once gets the app's own green button.
  That is the fail-safe direction.
- **A window replaced after more than 1.8 s** (an app rebuilding its only
  window) still looks like a last-window close. Activation and any window
  seen again cancel the looks, but a silent replacement cannot be told apart
  from a close. Only listed apps are affected.
- **An Accessibility read that returns "no value" counts as unknown**, not
  as zero windows. An app that answers that way when windowless will not be
  quit. Fail safe, by design.
- **Right-to-left is taken from the user's first preferred language**, not
  from each app, since an app's own layout direction cannot be read cheaply.
  An app localized against that direction falls back to its own green
  button.
- **No review claim was disproved.** Gemini's background window finding
  assumes macOS activates a window when its green button is clicked; that
  native behavior was not checked, the fix follows the brief.

### Unverified

- No live run (same reason as Stage 1). Not seen working: the hover cache,
  the held press replay opening the tiling menu, Command-W delivered with
  postToPid (Chromium and Electron apps in particular), the tail placement
  ordering against Windows keyboard mode, the Secure Input note.
- Bundle ids confirmed on this Mac: com.microsoft.rdc.macos (Windows App),
  com.citrix.receiver.icaviewer.mac (Citrix Viewer). The others come from
  Vorssaint's list and were not checked against installed apps.
- Whether some apps report the green button only as a child element that
  Accessibility hit testing returns at more than four levels deep; such a
  click would be dropped rather than performed.

## Stage 4b and 5 review fixes (2026-10-22)

Fixes for defects found by two independent reviews (Codex and Gemini) of Stage 4b (preview card buttons, Layouts menus) and Stage 5 (multi-row dock, per-display settings). Each claim was checked against the code before changing anything.

Fixed:

1. Dock editor on a side-dock override. The editor now takes the owning dock's resolved edge (DockContext.resolvedPosition) for both its window inset and its layout, instead of the global edge. Before, a Left override with a global Bottom measured the side dock's height and left the editor a sliver.
2. Close on a preview card. The card now stays until the window has left the live window list. The list is checked at 0.25, 0.75, 1.5 and 3 seconds; if the window is still there (for example a save sheet the user cancelled), the card stays. New outcome removeCardOnceGone.
3. Layouts submenu Option handling. The dock menus now use native alternate items, like the menu bar item: each layout is a pair, and AppKit swaps the row while Option is held. The captured-or-current OR is gone, so the label and the action always agree. ContextAction gained an optional alternateModifiers field.
4. Dock context menu Hiding and Position. They now read this dock's resolved values and write to its display override when that display is customized (position, size or hiding set), otherwise to the global setting it inherits. A theme or float offset alone does not count, matching the Displays toggle.
5. Magnification eligibility now compares the magnified size against this dock's own resting size (the same value the magnification model and MainWindow headroom use), so a smaller per-display tile size still magnifies.
6. Snap menu (and any menu opened from the preview). Opening it cancels a pending dismissal, and requestDismiss refuses while it is open. On close, the pointer is checked: over the preview keeps it, over the dock leaves it to the tile hover, anywhere else starts the normal dismissal grace.
7. Layout restore with no recorded display UUID. The frame is kept only when it is fully on a screen today; otherwise it is clamped onto the screen it overlaps most, or the main screen. The XCTest that pinned the old raw-frame behavior was replaced with two tests.
8. Save name collision. The replace check now reads the layout names again after the modal alert returns.

Regression checks added: scripts/test-preview-actions.sh (close outcome, live-list match, menu-close decision), scripts/test-perscreen.sh (which store the dock menu edits, magnification room), scripts/test-dock-rows.sh (6 items in 4 rows), WharfTests WorkspaceLayoutModelTests (nil UUID restore).

### Deviations

- Gemini A5 (Snap from a card targets the pointer's display): disproved. WindowSnapService.perform picks the screen with the largest overlap of the window's live frame and uses NSScreen.main only when the window overlaps no screen. No change.
- Gemini B1 (row math leaves rows empty): disproved as a defect. 6 items in 4 rows gives ceil(6/4) = 2 per row, so 3 full rows. The documented contract is "at most rowCount rows", and the drawing (sectionTilesView) and measuring (sectionExtent) both call the same chunk, so they cannot disagree. Pinned with a check.
- Gemini B2 (divider resize feedback loop): disproved. A divider's extent comes from TileContainerView.size(for:), which is tileSize * 0.5 by tileHeight, both inputs, never the rendered bounds.
- Gemini A3 follow-on (case-insensitive replace check vs exact capture match): not a defect. replacesExisting already matches exactly, and an existing check pins that.
- Gemini B3, B4, B5 were outside this fix list and were not changed.
- Magnification fix has no standalone check beyond the comparison helper, since the eligibility lives in a SwiftUI view.

### Unverified

- The editor on a display with a side-edge override (no live UI run).
- Close with an unsaved document and a cancelled save sheet.
- Snap menu dismissal timing during real menu tracking.
- Live Option switching inside the dock's cartouche menu (the private popup path); the menu bar item uses the same pattern and works.

## 2026-10-22, Command Bar review fixes

Two independent adversarial reviews of the Stage 4a Command Bar (Codex and
Gemini) were checked claim by claim against the code. Every claim on the fix
list was confirmed by reading the code; none was disproved. Fixes:

1. **Destructive commands need a second Return.** Menu commands whose titles
   say Quit, Force Quit, Log Out, Sign Out, Delete, Erase, Empty Trash, Move
   to Trash, Shut Down, Restart, Remove, Discard, Reset, Revert, Clear, Close
   All and similar (`CommandBarSafety`), plus an app's Quit action and a
   window's Close action, show in red, are never selected by default, and
   the first Return or click only shows a red "Press Return again" line;
   the second one runs it. Escape, moving the selection, typing, or that row
   leaving the list cancels it. The application menu's Quit is left out of
   the menu results entirely (the app row's Tab actions still offer Quit,
   behind the same confirmation).
2. **Selection follows the row, not the row number.** Late menu and file
   results keep the selected row selected; if it disappears, selection falls
   to the first row that is safe to preselect, or to nothing at all.
   The action list closes when its row goes away.
3. **Nothing cached runs without a recheck.** Menu commands: the app in
   front must still be the one the bar opened over; then, off the main
   thread with a 0.25 s timeout, the item must still belong to that process,
   carry the same title and be enabled (an unreadable enabled state counts
   as disabled). Window actions and snaps: the app must still run under the
   same bundle identifier and the window number must still exist and belong
   to that process (window server lookup, no Accessibility call). A failure
   keeps the bar open and says why in it. History is recorded only after an
   action reports success.
4. **Off the main thread, with timeouts:** the focused window read when the
   bar opens (only when snapping is on), the whole menu walk, the menu
   recheck and the menu press. Every menu element read gets its own short
   timeout, since a timeout set on the app element does not carry over.
5. **The bar closes when another app comes to the front**, as well as when
   it stops being key.
6. **File results are tied to their query.** They are dropped on every
   keystroke, only shown while their exact query is still typed, and their
   row IDs include the query.
7. **History holds no document names.** Menu commands are not remembered at
   all, and any menu entries an earlier build stored are dropped on load.
   Loaded history is checked: counts clamped to 0 to 1000, keys over 256
   bytes dropped, at most the newest 200 kept; counting saturates, so a
   damaged store cannot crash Wharf.
8. **Menu walk budget:** at most 2500 nodes visited (disabled items count),
   1.5 s, children fetched in bounded batches, one walk at a time on a
   serial queue, and an older walk is cancelled when a new one starts.
9. **Spotlight:** only the home folder (skipped when it is on a network
   volume) and /Applications; Library and anything with a hidden (dot)
   folder or name is filtered out. Partial results show as they gather; the
   query stops when it has enough, finishes, or hits a 1 s deadline, and
   only a bounded prefix of hits is ever examined.
10. **Query size is capped at entry** (256 Unicode scalars, 1024 bytes)
    before any trimming or folding, and the ranking folds the query once per
    keystroke instead of once per candidate.
11. **Numbers are parsed strictly.** Grouping commas must form real groups
    and may not follow a decimal point (1.2,345 is refused in the converter
    too). Where the comma is the decimal mark, a comma in a number, or a dot
    followed by exactly three digits, shows an "Ambiguous number" row with
    nothing to run instead of a guess.
12. **Shortcut conflicts stay current.** The bar re-checks its shortcut
    whenever Windows Keyboard Mode, the snip shortcut, the Launchpad or
    Window Switcher shortcut or any snap shortcut changes. A conflict turns
    the bar's hot key off and the settings pane says why.

Checks added to `scripts/test-command-bar.sh` (now 359): destructive
classification, ID-based selection, hostile and oversized history, saturating
counts, query limits against a two million mark grapheme, strict and
locale-aware number parsing, and the file path filter.

### Deviations

- Ambiguous numbers are refused with a note rather than parsed by locale.
  The calculator only reads dots as decimals, so guessing in a comma locale
  could still be wrong. In those locales "1,5 + 1" now shows the note too.
- Window actions (focus, minimize, close, snap) still run on the main thread
  through WindowRegistry and WindowSnapService, which own their state on the
  main thread; they stay bounded by Wharf's existing 1 s global Accessibility
  timeout. Only the bar's own Accessibility calls named in the fix list were
  moved.
- The window read at open no longer re-syncs the registry: a focused window
  the registry has not tracked yet gives no snap target ("There is no window
  in front to snap") instead of a sync on the main thread.
- A menu command is pressed after the bar closes (as before, so it lands on
  the app's own window); if the press itself then fails, Wharf beeps, since
  the bar is gone.
- The destructive word list is English only.
- Not on the fix list and left alone: the bar opening on the display under
  the pointer rather than the active window's, and the snap shortcut
  recorder not knowing the bar's shortcut (Gemini 8 and 9).

### Unverified

- Behavior against live apps: a hung app, a menu that changes while the bar
  is open, Command-Tab closing the bar, the confirmation line, and Spotlight
  partial results and deadline timing. Only the build and the logic checks
  were run.
- A network home folder (no test machine has one).
- The menu walk now treats an item whose enabled state cannot be read as
  disabled. An app whose menu items do not publish that attribute will show
  no menu commands where it showed them all before. That is intended (fail
  closed), not a regression.
- The new conflict check turns the hot key off on a conflict. Wharf's own
  defaults (Launchpad unset, Window Switcher Option-Tab) do not collide with
  the bar's Option-Space, so a fresh install is unaffected.

## 2026-10-22, Code review chunk 1 patches (green button)

Branch `cr1-green-button`, from `feature/vorssaint-parity`. Files:
`Docky/Services/GreenButtonMaximizeService.swift`, the green button parts of
`Docky/Services/WindowBehaviorLogic.swift`,
`Tests/WindowBehavior/WindowBehaviorLogicTests.swift`,
`scripts/test-window-behavior.sh`. The quit guard code was not touched.

1. HIGH, done. The hit test now ends on any on screen window that covers
   the point and is not fully transparent (menus, popovers, floating
   panels, small windows, Wharf's own windows): the click goes to that
   window. Only layer 0 app windows get the traffic light area test. The
   two old checks that expected menus and small windows to be seen through
   now expect nil; new checks cover a menu layer window, a floating panel,
   a same app popover, a Wharf window, a transparent window and a menu that
   does not cover the point.
2. HIGH, done. Every give-up path in `perform` (missed hit, window not
   found, nothing to restore, maximize and native press both failed,
   disabled button, sheet or modal) replays the held press and release to
   the app with the synthetic marker. A source guard in the test script
   counts the replay calls.
3. MED, done. A preflight right before acting re-reads the button's
   enabled state, looks for an attached sheet among the window's children,
   and checks the window list for a modal panel (level 8) of the same app.
   Any of these replays the click.
4. MED, done. The move throttle keeps a trailing check
   (`GreenButtonMoveThrottle`, tested). A release after a passed drag
   refills the cache for the window under the pointer. After a successful
   move the cached answer follows the window at once (button shifted with
   the window's top leading corner, `GreenButtonLogic.shiftedButton`,
   tested), then a fresh lookup runs at 0, 0.15 and 0.6 seconds. Lookups
   use one serial queue per app.
5. MED, partial. The tap reads the window list only when a cached button
   frame is under the press; a press near a title bar with no cached answer
   schedules a lookup after the event is passed; a press elsewhere costs a
   scan of a short array. The system wide element is gone: the hit test
   asks the app element, with the timeout set on it. Because an app scoped
   hit test cannot see another app's window that came in front after the
   press, the preflight first checks the window server that the target is
   still the front window at the point (the cover the system wide hit test
   used to give); if not, the click is replayed. The hit test, enabled
   and sheet checks, modal check and frame read run on the app's lookup
   queue. Left on main: `WindowRegistry.liveWindows`, `focus`,
   `setFullscreen`, `liveFrame` (only as a fallback) and
   `WindowSnapService.perform`, because those services are main actor.
6. LOW, done. The window is focused when its app is not in front or when
   the window is not the app's main window (read in the preflight).
7. LOW, skipped. See Deviations.

### Deviations

- Item 7 was not applied because the claim does not hold for this class.
  `WindowBehaviorPreferences` is `@Observable`, and the macro turns each
  property into an accessor, so assigning the clamped value inside `didSet`
  runs `didSet` again and stores it. A reduced model (an `@Observable` class
  with the same clamp and return) was compiled and run: setting 50 with a
  cap of 10 left 10 and ran the store branch with 10. Note the review's
  premise is true for a plain class, so the clamp would break if
  `@Observable` were ever removed.
- Item 4 asked for "a deadline". Each Accessibility element already has a
  0.35 second messaging timeout; with one queue per app, a hung app only
  delays its own lookups, so no separate overall deadline was added.
- A click is not replayed when the user has pressed again before Wharf
  finished with it: replaying it then would land inside the newer press and
  split that press from its release. That case is logged and the old click
  is dropped.
- The modal check uses the window server (an app window at level 8)
  instead of asking the app element for its focused window, to keep the
  rule of never questioning the application element beyond its window
  list.
- The raise in item 6 uses the window's main flag from the preflight rather
  than `WindowRegistry.frontmostWindow()`, which would ask the application
  element on main.

### Unverified

- Nothing was clicked on real windows. Only the build, the logic checks and
  a read only window list were run.
- The read only window list showed Wharf's dock strips as layer 0 windows
  and Notification Center widgets at a desktop layer. Neither sits over a
  title bar in normal use, but a window dragged under a Wharf dock now has
  its green button left to the app there (the click goes to the dock).
- A replayed click is posted at the original press location, so if the
  pointer moved in the few milliseconds before the replay the cursor jumps
  back there. On a full screen style green button the replayed click enters
  native full screen, the same tradeoff the existing native press path
  already makes.
- Whether `NSAlert` run modally always sits at window level 8 in every app,
  and whether every app exposes sheets as children with the sheet role.
- Asking the app element for the element at a point (instead of the system
  wide element) was not checked against Chromium apps.
## 2026-10-22, Code review chunk 1 patches (quit guard)

Patches from the BMAD adversarial review of the Window Behavior chunk, for
Command-Q and Command-W protection and quit on close. The green button items
were handled separately. Rule followed throughout: when unsure, never swallow
input and never quit or close anything. Branch `cr1-quit-guard`.

What changed, by review item:

1. A hold no longer confirms from time alone. When the hold ends, Wharf asks
   whether the key and Command are still physically down; if either was let
   go unseen, the hold cancels.
2. When macOS briefly turns the key watcher off mid-press, keys Wharf already
   held back stay held, and a repeat of a protected shortcut with Command is
   swallowed until a key-up or a fresh press. Held keys are forgotten after
   10 seconds of silence, so a release missed under Secure Input cannot leave
   the guard stuck.
3. After turning the watcher back on, Wharf checks it really is on. If not,
   it rebuilds it (0.5, 1, 2, 4, 8 seconds apart, at most 5 tries, the count
   starting fresh after a quiet minute) and the pane shows an orange
   "Protection is inactive" line while it is down.
4. Keyboard layouts that type no Latin letters (Russian, Greek, Hebrew) now
   match Command-Q and Command-W by key position, as macOS does.
5. Shift-Command-Q (Log Out) and Control-Command-Q (Lock Screen) always pass
   through to macOS.
6. Wharf also asks Accessibility which app owns the keyboard (cached, read off
   the key path when Command goes down and after each app switch). If that is
   not the app in front (a Spotlight style panel, or an app switch not yet
   announced), the shortcut passes untouched. Right before acting, a fresh
   read must also agree.
7. Close tells apart "the app has no window in front" (its own message,
   nothing closed) from "the app cannot be asked at all" (Command-W is sent,
   as it would be without Wharf).
8. About half a second after sending Command-W, Wharf looks again (window
   gone, title changed as when a tab closes, window count changed). If
   nothing at all changed, the HUD says it could not confirm anything closed.
9. Quit on close: an app asked to quit once (and kept open, say from a save
   prompt) is armed again by any window it shows after the user brings it
   forward, and a window's subrole is read again half a second later. When a
   listed app is left running because a window is still there, the pane says
   so ("skipped, window still present").
10. The HUD shows on the screen of the target app's front window, and long app
    names wrap onto more lines instead of being cut off.
11. Bundle id lists are written back sanitized from the pane on every add and
    remove, and per-app protection keys are normalized (one entry per bundle
    id ignoring case, display spelling kept, first in sorted order wins).
12. The reset confirmation now lists everything it resets, read from the real
    default values.
13. `start()` on QuitGuardService and QuitOnCloseService is now safe to call
    twice. Before, a second call added duplicate observers (wasted work, no
    wrong behavior, since the tap and observers were already guarded).

Checks: `scripts/test-window-behavior.sh` now also builds and runs
`Tests/WindowBehavior/QuitGuardReviewTests.swift` (66 checks, in its own file
so the green button work does not collide), plus source guards for the
service-side fixes (key recheck, tap health check, focus owner check, no
clipped HUD text, run-once start). Three existing checks were updated for the
new layout and system chord rules. Build succeeded; all eight
`scripts/test-*.sh` pass.

### Deviations

- Item 4: the fallback to key position applies only when the typed character
  has no ASCII in it, not whenever it is "not an ASCII letter". On Dvorak the
  US Q key types an apostrophe, and Command-' is a real, different shortcut;
  falling back there would hold back Command-' and then quit the app.
- Item 5: passing the system chords alone would leave Command-Q unconfirmable
  in Extra Modifier mode with Shift (the default) or Control, and the HUD
  would tell the user to press Log Out. So Command-Q now always confirms with
  Option-Command-Q, whatever extra modifier is chosen; Command-W keeps the
  chosen one. The pane text says so.
- Item 1: "still down" accepts Control in place of Command when the press
  arrived through Windows keyboard translation (Control-Q turned into
  Command-Q in flight), since physical Command is never down then.
- Item 6: a failed or not-yet-returned focus read counts as "unknown" and does
  not override the app-in-front tracking. Treating unknown as "pass" would
  switch protection off whenever Accessibility is slow.
- Item 9: "re-arm on a fresh windowless period after activation" is done as:
  after an activation, any window counts as the start of a fresh stretch.
  Quit on close also keeps looking for the whole round after an early look
  sees a window (it still never quits that round) so the last look can say
  whether the window stayed; quitting behavior is unchanged.
- Item 11, partial: `storeList` lives in WindowBehaviorPreferences.swift, which
  this pass was not allowed to edit. The pane now always writes sanitized
  lists, but a list edited any other way can still differ between memory and
  disk. One-line fix for whoever merges: in `storeList`'s `didSet`, assign
  the sanitized value back to the property (as the hold slider clamp does).
  Duplicate override keys already on disk still show twice in the pane, but
  matching uses one of them deterministically.
- Item 13: GreenButtonMaximizeService was left to the other agent, as agreed.

### Unverified

- No live key presses were driven. Not checked against real apps: the
  physical key read under Secure Input, the tap death and rebuild path (it
  cannot be forced on demand), whether Spotlight's panel reports itself as
  the focused application, the Command-W confirmation on browsers and apps
  with save sheets, the HUD on a second display, and quit on close with apps
  that keep invisible windows.
- Whether `CGEventSource.keyState` with the combined session state reflects
  keys remapped by tools such as Karabiner. If it does not, a hold cancels
  (the safe direction).
- The "could not confirm" note may show for an app that handles Command-W
  without any visible change Accessibility can see.

## 2026-10-22, Code review chunk 1 re-check (green button)

Codex and Gemini re-attacked the chunk 1 green button patches. Principle
applied throughout: when unsure, the click goes to the app untouched; a
click Wharf already held back is handed back only to the exact window and
button it was aimed at, otherwise it is canceled quietly. A lost click is a
nuisance; a click landing on a different window can do damage.

Done:

1. (Codex 1, high) Replay onto a different window. `replay` now confirms,
   right before posting, that the original window is still in front at the
   point with the same frame (window server, on main) and that
   Accessibility still finds the green button there (on the app's lookup
   queue). Any mismatch cancels. A preflight `.missed` no longer replays at
   all. The hold path (tiling menu) checks the window the same way before
   handing the press back. Logic: `GreenButtonLogic.mayReplay`.
2. (Gemini 1, high) Replay loop. Disproved the premise (below), but added
   the second guard anyway: `GreenButtonReplayGuard` leaves a 0.5 s token at
   each replay point that the tap recognizes and spends, allows one replay
   per press serial, and refuses more than 4 replays in 2 s, so even if both
   the marker and the token failed a loop dies within 4 rounds (tested).
3. (Codex 3, high) Partial restore. After a failed snap the window frame is
   read again; `GreenButtonLogic.outcome` gives completed, no action (frame
   readable and unchanged) or partial/unknown. Only no action replays or
   falls back to the native press; partial/unknown spends the click. A
   native press that times out is also treated as unknown (no replay).
4. (Codex 5, medium) Late work. Every click carries the service generation
   (bumped on tap build, tap removal, settings change, and tap interrupt)
   and its press serial; `perform`, `act`, `replay` and the replay post all
   check both and that the feature is on. The window frame is rechecked
   just before focus and the move; the delayed cache follow-ups stop after a
   generation change.
5. (Codex 7, medium) Click-through overlays. Wharf's own windows with
   `ignoresMouseEvents` (the quit protection HUD) are passed to the hit test
   as `ignoredWindowIDs` and seen through. Other apps' click-through
   overlays cannot be detected from the window server list, so they still
   end the scan and the click goes to the app (safe direction).
7. (Gemini 5, medium) The native button press (both the zoom fallback and
   the Option full screen fallback) now runs on the app's lookup queue.
   Left on main by design: `registry.focus`, `setFullscreen` and the
   `WindowSnapService` move, which are main actor services bounded by the
   registry's messaging timeout. A newer click arriving in the moment
   between dispatching the native press and the press itself is not
   rechecked on the queue.
8. (Gemini 7, medium) Rapid double click. Decided to keep dropping the
   first click's pending work when a second press arrives (now covering the
   action too, not only the replay). The second click is evaluated on its
   own: it toggles once, the same as one click. Every replayed press and
   release is sent as a single click (click count 1), so a dropped first
   click cannot turn a replayed second click into a title bar double click.

Deviations (disproved):

- Gemini 1 premise: "HID posting strips eventSourceUserData." Tested on
  this Mac with a listen-only session tap: a mouse move carrying the marker,
  posted at `.cghidEventTap`, arrived at the session tap with the marker
  intact. The guard in item 2 was added regardless, because the test used a
  mouse move and a listen-only tap rather than a left press seen by a
  default tap. `postToPid` was not adopted: mouse events sent that way skip
  the window server's routing, and it was not tested.
- Item 6 (Gemini 3, shadow margin): not changed. Compared
  `kCGWindowBounds` with the Accessibility frame of six real windows
  (Claude, Spotify, Screen Sharing, Brave, Chrome, VS Code): identical to
  the point. The window server bounds do not include the drop shadow, so an
  inset would only let clicks on the edge of a front window fall through to
  the one behind.
- The `.missed` preflight result mixes "another window in front" with "same
  window, but Accessibility no longer finds the button (or timed out)". Both
  now cancel, following the brief's "control is still what it was" rule,
  rather than replaying to the same window.

Tests: `Tests/WindowBehavior/GreenButtonReviewTests.swift` (35 checks) runs
as its own program from `scripts/test-window-behavior.sh`; the old source
guard that required a replay on every give-up path was replaced by guards
that the replay and hold paths go through the target gate and the replay
guard, that `.missed` and partial moves never replay, that the tap has the
second replay check, and that the native press runs in one place on a
lookup queue.

Unverified:

- No live clicks were driven. Replay, cancel and hold behavior on real
  windows, and the tiling menu after a hold, are checked by logic and
  source guards only.
- Whether a canceled click in a real app feels like a missed click rather
  than a stuck state (the press and release are both withheld, so no
  stuck button is expected).
## 2026-10-22, Code review chunk 1 re-check (quit guard)

Codex and Gemini re-attacked the chunk 1 quit guard fixes. Each claim was
checked against the code first. Principle throughout: when unsure, never
swallow input and never quit anything; for the focus check that means
protect.

Done:
1. Stale focus owner (Codex 2, real). The cached "who has keyboard focus"
   answer now lives in `QuitGuardFocusCache`: every fresh key press makes it
   unknown (Escape or Return can dismiss a panel, Command-W can close one),
   an answer older than 1.5 s is unknown, and a read that started before an
   invalidation is dropped. Unknown protects. Reads refresh on Command or
   Control going down (the Windows translation rewrites only key events, so
   its modifier event never carries Command) and after each Command key.
   Reads are coalesced: one in flight, at most one more queued.
2. Helper processes (Gemini 2). `QuitGuardProcess.belongs(to:)` counts a
   focus owner as the front app when it is the same process, its child, a
   bundle id under the front app's (dot boundary), or a bundle inside the
   front app's bundle. One way only. Used in the tap and in the revalidation
   right before a confirmed action.
3. Dialogs re-arming quit on close (Codex 4, Gemini 4, real). Windows are
   classified by `QuitOnCloseWindowKind.classify` from subrole and AXModal.
   A modal window is a dialog whatever its subrole; dialog, panel and
   AXUnknown subroles never re-arm; an unreadable subrole or modal flag is a
   doubt and never re-arms. A standard window re-arms; an ordinary
   (readable custom subrole, not modal) window re-arms only after the user
   activated the app. Activation alone never re-arms.
4. System wide timeout (Codex 6, real). The call is gone; the focus read
   runs on its own queue under the 1 s default AppDelegate sets. The
   revalidation before a confirmed action no longer blocks the main thread:
   it reads on the focus queue and gives up after 0.3 s (unknown).
5. Ownership expiry (Codex 8, Gemini 10, real). `prune` ran before the
   arriving key's own ownership check, so a repeat after a quiet gap passed.
   Now the arriving key is checked first; a key quiet past 10 s leaves
   flight but stays in `quietOwned`, so its repeats refresh and are
   swallowed and its key-up is swallowed. Only its key-up, a fresh press, or
   switching protection off ends ownership. The service routes such keys to
   the machine even when nothing is in flight.
6. Retry counter (Gemini 6, real). `QuitGuardTapRetry` resets the count once
   a rebuilt tap has stayed enabled for 10 s. A tap that dies right after
   each rebuild still backs off and stops after five tries.
8. False "could not confirm" (Codex 9, Gemini 11, real). The post check and
   its message are removed: unchanged title and count is always ambiguous
   for tabbed apps. Nothing is said after a Command-W is sent.
9. Option-Command-Q (Gemini 9). Rule unchanged. The settings line now shows
   always and says Option-Command-Q is the confirm key for Quit in Extra
   modifier mode and that it replaces Quit and Keep Windows.

Regression checks: QuitGuardReviewTests sections 9 and 12 to 15, plus
source guards in scripts/test-window-behavior.sh (no timeout on the system
wide element, no "could not confirm", quiet keys routed to the machine,
AXModal read, settings text).

### Deviations
- Item 7 (Gemini 8) disproved, no change. The Windows keyboard translation
  rewrites flags only, never the key code (WindowsKeyboardService line 385),
  so `keyState` on the physical key code is right. Dvorak and other layouts
  change characters, not key codes. Modifier remaps in System Settings are
  applied below the event system and show in the combined session state.
  A tool that rewrites key codes inside its own event tap would make a hold
  cancel, which is the safe direction.
- Gemini 10's "hold longer than 10 s" only happened with key repeat turned
  off in System Settings (otherwise repeats refresh ownership); Codex 8's
  quiet gap then repeat was the real path. Both are fixed by item 5.
- Focus changes are not observed directly (no public notification for the
  system wide focused app); invalidation on every key plus the 1.5 s age
  limit stands in. Accepted cost: a fast second Command-W into a Spotlight
  style panel, or Command-W after holding Command over 1.5 s in one, is
  protected (the HUD shows; a confirm then finds the front app no longer
  owns focus and does nothing).
- Items 1 to 6 and 8 share files, so they are one commit rather than one per
  item; item 9 is its own commit.
- An app whose windows never report a readable subrole and AXModal stays
  "already asked" for that windowless stretch until it quits or relaunches.

### Unverified
- Whether Accessibility ever reports a helper process (Safari Web Content,
  a plug-in) as the focused application. The family check only widens
  "agrees", the safe direction. WebKit's shared helpers live outside the
  app bundle and do not share its bundle id, so they would not match.
- AXModal support in non AppKit windows (Java, some game engines); a missing
  value is treated as a doubt.
- No live run: the tap, the HUD and quit on close were not driven against
  real apps in this pass.

## 2026-10-22, Code review chunk 2 patches (keyboard listener)

Branch `cr3-keyboard` from `feature/vorssaint-parity`. Patches from the BMAD
adversarial review of the Win tap and Windows keyboard chunk. Principle held
throughout: when unsure, do nothing rather than open something or swallow a
key.

### What changed
1. Media keys and window server shortcuts. System-defined events (type 14:
   volume, brightness, media keys) are in the tap mask and cancel a tap. For
   Command+Tab, Command+Space and other shortcuts the window server may
   consume before the session tap, the release asks the hardware layer
   (`CGEventSource.secondsSinceLastEventType(.hidSystemState, ...)` for key
   down and type 14) when it last saw a key go down; a key at or after the
   Command press (with 50 ms of slack before it) cancels the tap. Modifier
   keys are flag changes, not key downs, so Command never cancels itself.
   This needs no extra permission (it answered from a plain command line
   tool with no prompt).
2. Mask by action. `WinTapEvents.mask(for:)`: key down and key up only when
   the Win key action is Nothing; modifiers, clicks, scrolls and media keys
   added otherwise. The tap remembers its mask and is reinstalled when the
   wanted mask changes. Each event now takes the state lock once (a
   snapshot of action, snip settings and exclusion), and the detector is
   reset in place only when it holds state, never rebuilt per event.
3. Hold time from the event's own stamp. `WinTapEvents.eventTime` converts
   `CGEvent.timestamp` through the mach timebase, also tries plain
   nanoseconds, and trusts a reading only when it lands within one second
   before the callback's own clock; otherwise it uses the callback time, as
   before. A negative hold never fires.
4. Stale state. `CommandTapDetector.reset()`; the detector and the snip
   latch reset when the tap is re-armed after a timeout or user-input
   disable, and on every install (a flag set under the lock, consumed by the
   tap thread on its first event).
5. Snip in excluded apps. Win+Shift+S now passes through untouched in an
   excluded app, so a remote desktop or virtual machine gets its own. New
   switch "Take Snips in Excluded Apps Too", key
   `wharf.windowsKeyboardSnip.inExcludedApps`, default off, in
   BehaviorExtrasPreferences (keys, default, property, init, reset: each a
   line appended at the end of its block). Footer text rewritten.
6. `windowsKeyboardExcludedBundleIDs` is passed through
   `BundleIDList.deduplicated` on load; the editor's remove button uses the
   new case-insensitive `BundleIDList.removing`.
7. Apps without a bundle ID. The frontmost check uses
   `BundleIDList.matchKey` (bundle ID, else the executable's file name). The
   editor's Choose App falls back to the executable name and says so in an
   orange line, or says plainly why the app could not be added; Add Running
   App lists such apps too. Opt-in per list (`allowsExecutableNames`), on for
   the Windows keyboard list only.
8. Orange note under the Win Key picker when Launchpad is picked and the
   Launchpad overlay is off, naming Features, Launchpad, Enable Launchpad.
9. Typed bundle IDs go through `BundleIDList.validationError`: two or more
   dot separated parts of ASCII letters, digits and hyphens. The reason for a
   refusal shows under the field and Add is disabled; Return is checked too.

Regression checks added to `scripts/test-focus-and-wintap.sh` (109 to 161):
system-defined key cancels, hardware key during the hold cancels (and one
well before it does not), detector reset, negative hold, mask by action,
timestamp conversion for ticks, nanoseconds, Intel and implausible stamps,
stamp-based hold, snip decision, dedupe on load, case-insensitive removal,
bundle ID validation, executable-name match key.

### Deviations
- Item 5 premise was half right: the old footer already said "Win+Shift+S
  still takes a snip everywhere", so the code did not contradict the text.
  The underlying point (remote desktops and virtual machines should get the
  guest's own Win+Shift+S) stands, so the fix was applied as asked.
- Item 1, window server shortcuts: instead of the suggested "frontmost app
  changed or Spotlight became active" guard, the release checks the
  hardware's last key down. It covers every swallowed shortcut, not just two
  known ones, and does not race the app activation notification, which for
  Command+Tab arrives after Command is released.
- Item 9: underscores are refused, as asked (letters, digits, dots,
  hyphens) and as Apple's rules for the key say. A real app with an
  underscore in its ID can still be added with Choose App or Add Running
  App, which skip validation. The same validation now applies to the focus
  follows mouse list, which shares the editor.
- Item 7: the executable-name fallback is not offered on the focus follows
  mouse list, since its gate (owned by the other agent) matches by bundle ID
  only; there the picker shows the "could not be added" line instead.
- Items 1 to 4 share the same functions and are one commit; items 6 and 9
  are one commit (same helper block, editor and tests).
- Duplicates in the stored list are collapsed in memory on load; the stored
  value is rewritten the next time the list is edited, not at launch.

### Unverified
- Whether the session tap really never sees Command+Tab or Command+Space key
  downs. Not probed: it would mean posting synthetic Command events into the
  live session. The hardware check is the conservative guard either way.
- Units of a real `CGEvent.timestamp` on this machine. A freshly created
  event carries 0, so only a real keystroke would tell; the conversion tries
  both readings and falls back to the old behavior when neither fits.
- That `secondsSinceLastEventType(.hidSystemState, .keyDown)` never counts a
  modifier key. Modifier keys are flag changes at the HID layer, so it should
  not; if it did, every tap would be cancelled (the safe failure). To make
  that visible, a tap stopped only by this check writes a line to
  `wharf-keyboard-status.txt` (from a background queue, never the tap
  thread): if every tap reports it, this assumption is wrong.
- No live run of the tap, the snip in an excluded app or the Settings
  changes.
