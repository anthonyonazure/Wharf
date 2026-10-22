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
