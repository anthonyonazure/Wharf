# Wharf — User Acceptance Tests

Manual, black box. No code reading. Anyone with a mouse and three monitors can run these.

## How to run them

**Reset before each section.** Quit Wharf, relaunch it, and start from a known state:
the default profile, autohide off, dock mode (not taskbar), previews on. A test that
only passes because of leftover state from the previous test is not a pass.

**Repeat rule.** Any test in the Smoke or Regression sections must pass three times in
a row. Intermittent is a fail. The three bugs that shipped in August 2026 were all
intermittent, and all three were reported as "sometimes".

**Pass bar for a release.** Every Smoke test passes, every Regression test passes, and
no test anywhere fails in a way that leaves the machine without a usable dock.

**Record the build.** Before starting, note the version from the menu bar item. Results
from different builds are not comparable.

---

## 0. Smoke suite (the release gate)

Twelve tests. If any of these fail, the build is not usable and there is no point
running the rest. Should take under fifteen minutes.

| # | Test | What it protects |
| --- | --- | --- |
| S1 | A1, click a running app's tile, its window comes forward | The core promise |
| S2 | A3, click a stopped app's tile, it launches | The core promise |
| S3 | R1, click a tile while deliberately jiggling the mouse | Regression: swallowed clicks |
| S4 | R2, remote session on display 1, click the dock on display 2 | Regression: dead docks on other screens |
| S5 | R3, install a new build over the old one, permissions hold | Regression: permissions dying on rebuild |
| S6 | B1, a dock is drawn on every connected display | The reason this fork exists |
| S7 | A8, click the tile of an app whose only window is minimized | Most common real world click |
| S8 | F4, taskbar mode, click a card, that exact window comes forward | Taskbar mode is unusable if wrong |
| S9 | D3, reveal an autohidden dock and click immediately | The reveal race |
| S10 | M4, force quit Wharf, the system Dock returns | Never strand the user |
| S11 | J4, Win+Shift+S captures a region to the clipboard | The headline keyboard feature |
| S12 | B5, unplug a display and replug it, its dock returns | Every desk does this daily |

---

## 1. Regression tests (each must be able to fail on the old build)

These three exist because they shipped broken. Each is written so that it would have
failed on the build from before the fix. A regression test that cannot fail on the old
build is not testing the bug.

**R1. Click drift.** Press a tile and, while the button is down, move the mouse five to
eight pixels in any direction, then release. The app launches or its window comes
forward. Repeat ten times, drifting a different direction each time. Ten out of ten
must act. *Old build: roughly one in three did nothing at all.*

**R2. Cross display stacking.** Put a remote desktop client (Windows App, Citrix,
Parallels) fullscreen on display 1. Confirm its own taskbar along the bottom is visible
and not covered. Now, without touching display 1, click a tile on display 2's dock. It
responds. Also confirm display 2's dock is still drawn above the ordinary windows on
display 2, not buried behind them. Switch away from the remote client: display 1's dock
returns to the front within one second. *Old build: every dock on every display sank,
so displays 2 and 3 were drawn but dead.*

**R3. Permission survival.** Note that Accessibility and Screen Recording are both on
for Wharf. Install a newer build over the top of the current one and relaunch. Both
permissions still work: Ctrl+C translates, and a hover preview renders. Neither
System Settings nor a prompt asks you to grant anything again. *Old build: every new
build silently lost both, while the switches still showed as on.*

---

## A. Clicking a tile

The core contract. If this section is shaky, nothing else matters.

- **A1.** Click a running app's tile. Its frontmost window comes forward and takes focus.
- **A2.** Click the tile of an app with three open windows, repeatedly. Focus cycles through all three in a stable, repeating order. No window is skipped, none is visited twice per cycle.
- **A3.** Click the tile of an app that is not running. It launches, and the running indicator appears within two seconds.
- **A4.** Click the tile of the app that is already frontmost. Run this once per setting: with "hide", it hides. With "minimize", it minimizes. With "cycle windows", it moves to the next window. With "do nothing", nothing happens. Each setting does exactly what its label says.
- **A5.** Click a tile using a trackpad, pressing hard enough that the cursor drifts. The click registers.
- **A6.** Click 20 tiles in a row as fast as you can. All 20 act. None is swallowed.
- **A7.** Click the tile of an app that is hidden with Cmd+H. It unhides and comes forward.
- **A8.** Click the tile of an app whose only window is minimized. The window un-minimizes and comes forward. It does not just bounce or do nothing.
- **A9.** Click the tile of an app whose windows all live on another Space. The Space switches and the window is frontmost.
- **A10.** Click the tile of a running app that has no open windows at all (Mail with every window closed). It either opens a new window or clearly activates the app with its menu bar. It never looks dead.
- **A11.** Right click a tile. The menu opens under the cursor and the tile does not move.
- **A12.** Modifier click a tile (whatever the setting binds). If the app supports multiple windows or documents, a new one opens. If the app does not support that, nothing bad happens and the app simply activates.
- **A13.** Click a tile for an app that is mid launch, then click it again two seconds later. The second click does not launch a second copy.

## B. Multi display

- **B1.** With three displays connected, a dock is drawn on every one.
- **B2.** Click a tile on display 2's dock. The window comes forward **on the display the window already lives on**, and that display's dock shows it as frontmost. Write down which rule the product intends before running this, and hold it to that rule.
- **B3.** In per screen mode, each dock lists only the windows living on its own display. Move a window from display 1 to display 3 and confirm both docks update within two seconds.
- **B4.** Unplug a display. The remaining docks stay correct, nothing is orphaned, and no dock is left half off screen.
- **B5.** Replug that display. Its dock returns within five seconds, in the right position, without restarting Wharf.
- **B6.** Change a display's resolution. Every dock resizes and repositions correctly.
- **B7.** Change which display is primary. Docks follow and none ends up partly off screen.
- **B8.** Rearrange the display layout in System Settings. Docks land on the right screens.
- **B9.** Sleep the Mac with all displays attached, then wake it. Every dock returns, in place, within ten seconds.
- **B10.** Close the laptop lid with an external display attached. The internal dock disappears cleanly, no ghost is left behind, and the external docks are unaffected.
- **B11.** Mix display geometry: one display at a different scaling factor, one rotated to portrait, and the built in display with the notch. Every dock is positioned correctly, fully on screen, and takes clicks.
- **B12.** Put a different Space on each display. Switch the Space on display 1 only. The docks on displays 2 and 3 stay visible and clickable throughout.

## C. Stacking, fullscreen and remote sessions

- **C1.** Put an ordinary app fullscreen on display 1. Display 1's dock behaves per the fullscreen setting. Displays 2 and 3 are unaffected and still take clicks.
- **C2.** Open a remote desktop client fullscreen on display 1. Its own bottom taskbar is fully visible and not covered by Wharf.
- **C3.** While that remote session is frontmost, click a tile on display 2. It responds. Display 2's dock is still drawn above ordinary windows on display 2.
- **C4.** Switch away from the remote client. Display 1's dock returns to the front within one second.
- **C5.** Maximize (not fullscreen) an ordinary window so it reaches the dock's edge. State the intended behavior first: either the window stops short of the dock, or it goes under it. Whichever it is, the dock still takes clicks.
- **C6.** Start a Zoom or Teams screen share of a display that has a dock. Join from a phone or second machine and look at the shared feed. Confirm whether the dock appears, and that it matches the setting.
- **C7.** Trigger a system alert or a full screen macOS dialog. The dock does not float over it.

## D. Autohide and reveal

- **D1.** Turn autohide on. The dock hides after the configured delay, plus or minus half a second.
- **D2.** Push the cursor to the screen edge. The dock reveals within the configured delay.
- **D3.** Reveal the dock and click a tile in one continuous motion, without pausing. The click registers. Repeat five times.
- **D4.** Move the cursor to display 2's edge while never touching display 1. Only display 2's dock reveals.
- **D5.** Drag a file toward the hidden edge. The dock reveals so the file can be dropped.
- **D6.** With autohide off, open ordinary windows over the dock's area. The dock stays on top and takes clicks. Known exceptions that do not count as failures: fullscreen apps, listed stay behind apps, and system overlays.

## E. Drag, drop and reorder

- **E1.** Drag a tile to a new position. It moves, and the new order survives a quit and relaunch.
- **E2.** Press a tile, move it four to eight pixels, and release. The tile returns to its original place and, critically, the app does **not** launch and no window is raised. This is the other half of R1: the drag threshold must be low enough that a real drag works and high enough that a click is never eaten.
- **E3.** Drag an app from Finder onto the dock. It is added as a tile at the drop position.
- **E4.** Drag a tile off the dock. It is removed and there is a way to undo it.
- **E5.** Drag a file onto an app tile. The app opens that file.
- **E6.** Drag a file onto a folder tile. The folder springs open in Finder at that location. It does not silently move or copy the file.
- **E7.** Drag a tile from display 1's dock to display 3's dock. The tile appears in display 3's dock, is gone from display 1's, and the change survives a relaunch.
- **E8.** Start a drag and press Escape. The drag cancels and nothing moves.
- **E9.** Drag a tile and drop it out in the middle of the desktop. State the intent first: either it is removed with a poof, or it snaps back. It never vanishes silently with no way to get it back.

## F. Taskbar mode and window management

- **F1.** Switch to taskbar mode. Every open window has a card within three seconds.
- **F2.** Close a window. Its card disappears within one second.
- **F3.** Open a new window. A card appears within one second.
- **F4.** Click a card. That exact window comes forward, not a sibling from the same app.
- **F5.** Right click a card and use minimize, close, fullscreen and hide. Each does what it says. (Force quit is tested separately in F10 because it destroys work.)
- **F6.** Turn on grouping by app. Grouping is correct, and clicking a group expands it rather than raising an arbitrary member.
- **F7.** Rename a document. The card's label updates within two seconds.
- **F8.** Open 40 windows. The dock stays usable: cards shrink, scroll or wrap. Nothing runs off screen and no card becomes unclickable.
- **F9.** Open three documents in the same app with near identical names. Close the middle one, open a new one, then click each card in turn. Every card targets the right window. None targets a closed or stale one.
- **F10.** (Destructive. Run last, with nothing unsaved.) Right click a card and choose force quit. The app dies and every one of its cards disappears.

## G. Hover previews

- **G1.** Hover a tile with open windows. A preview appears after the configured delay.
- **G2.** Move the cursor away. The preview dismisses within one second and does not linger.
- **G3.** Sweep the cursor across five tiles quickly. Only one preview is on screen at any moment.
- **G4.** Click a preview thumbnail. That window comes forward.
- **G5.** Type into a window, then immediately hover its tile. The preview shows the text you just typed, not a stale frame from a minute ago.
- **G6.** Move a window to a different display and hover its tile. The preview shows the window, not a blank and not the wrong one.

## H. Widgets

- **H1.** Add each widget type in turn. Each renders with real data within five seconds.
- **H2.** Clock: the time matches the menu bar clock exactly. Change the system timezone and confirm it follows within one minute.
- **H3.** Calendar: create a real event ten minutes out. The widget glows. Delete the event and the glow stops.
- **H4.** Battery: the percentage matches the menu bar battery. System: the CPU and memory figures are within a few percent of Activity Monitor. Weather: the temperature matches the system Weather app for the same location.
- **H5.** Now Playing: start a track. The title is right, the progress bar advances, and play, pause and skip all work.
- **H6.** Shrink the dock to its smallest size. Widgets reflow or collapse. Nothing is clipped or unreadable.
- **H7.** Remove a widget. It goes, and stays gone after a relaunch.

## I. Launchpad and search

- **I1.** Open Launchpad. It fills the display it was invoked on, and only that one.
- **I2.** Type "textedit". TextEdit is the first result.
- **I3.** Press Return. TextEdit launches and Launchpad closes.
- **I4.** Press Escape. Launchpad closes and nothing launches.
- **I5.** Navigate to an app and launch it using only arrow keys and Return, no mouse.

## J. Windows keyboard mode

- **J1.** In TextEdit: Ctrl+C copies, Ctrl+V pastes, Ctrl+X cuts, Ctrl+Z undoes, Ctrl+A selects all.
- **J2.** In Terminal, run `ping 8.8.8.8`, then press Ctrl+C. The ping stops and nothing is copied to the clipboard.
- **J3.** In VS Code's integrated terminal, run `ping 8.8.8.8` and press Ctrl+C. State the configured behavior first. With the default settings it copies rather than stopping the ping, which is the documented trade off. Adding VS Code to the exclusion list flips it, and that flip must work.
- **J4.** Press Win+Shift+S. A crosshair appears. Drag a region, release, and paste into TextEdit. The image is there.
- **J5.** Press Win+Shift+S and press Escape. Nothing is captured and the clipboard is unchanged.
- **J6.** Hold Win+Shift+S down for three seconds. Exactly one crosshair appears, not a stack of them.
- **J7.** Turn the mode off in settings. Ctrl+C in TextEdit immediately stops copying, with no restart.

## K. Layouts and rules

- **K1.** Arrange windows across all three displays. Capture and save the layout.
- **K2.** Move every window somewhere else. Restore the layout. Every window returns to its exact position and size on the right display.
- **K3.** Quit one of the apps in the layout, then restore. The layout restores everything else and names the app that was missing. It does not fail silently and it does not hang.
- **K4.** Unplug a display the layout referenced, then restore. Every window lands somewhere visible and draggable. No window is placed off screen.
- **K5.** Undo a restore. Every window returns to where it was immediately before.
- **K6.** Create a time rule set two minutes out. At that minute the layout fires. (This path has never actually run. Treat a pass here as new information.)
- **K7.** Delete that rule. Wait through the next trigger time. Nothing fires.

## L. Permissions

- **L1.** On a Mac that has never run Wharf, launch it. It asks only for the permissions it needs and says in plain language what each is for.
- **L2.** Deny Accessibility. Everything that needs it (keyboard translation, moving windows, layout restore) is visibly marked unavailable, with a button to fix it. Nothing fails silently.
- **L3.** Grant Accessibility while Wharf is already running. Wharf notices and the features start working, either immediately or after clearly telling you it needs a restart.
- **L4.** Deny Screen Recording. Previews degrade with a visible explanation. Nothing crashes and nothing shows a blank grey rectangle with no message.
- **L5.** Install a newer build over the current one and relaunch. Every permission still works and nothing prompts again.
- **L6.** Revoke a permission in System Settings while Wharf is running. Wharf notices within thirty seconds and says so.

## M. Lifecycle and persistence

- **M1.** Quit and relaunch. Tiles, order, widgets, settings and per display configuration all return.
- **M2.** Log out and back in. Wharf starts on its own if set to, with the same state.
- **M3.** Reboot. Same.
- **M4.** Force quit Wharf from Activity Monitor. The system Dock returns within five seconds so the machine is never left without a dock.
- **M5.** Force quit Wharf while the system Dock is hidden and you are in a fullscreen app. You can still reach a dock or a task switcher without rebooting.
- **M6.** Launch a second copy of Wharf. The second one refuses or hands off. There is never more than one dock per screen.
- **M7.** Leave Wharf running through a full working day, then quit and relaunch. State is intact and nothing has drifted.

## N. macOS integration

- **N1.** With Wharf running, the system Dock is hidden per the setting.
- **N2.** Quit Wharf. The system Dock returns at its original position and size.
- **N3.** Change the system Dock's position in System Settings while Wharf runs. Nothing breaks.
- **N4.** Move a window to the very bottom edge of the screen, then click Wharf's tiles along that edge. Every click reaches Wharf. The system Dock does not pop up over it.
- **N5.** Open Mission Control, then App Exposé, then Stage Manager if it is on. No dock is stranded, duplicated or left as a ghost, and all docks are back to normal on exit.
- **N6.** Swipe between Spaces with a three finger gesture. The docks stay locked in place. They do not stutter, slide with the windows, or vanish and reappear.
- **N7.** Trigger Spotlight and Notification Centre over a dock. Both draw above the dock and dismiss cleanly.

## O. Settings and appearance

- **O1.** Work through this list, confirming each visibly does what its label says without a restart: dock position, dock size, magnification, autohide, display target, dock versus taskbar mode, window grouping, tile click action, theme, and the stay behind app list.
- **O2.** Change a setting, then quit without doing anything else. It persists.
- **O3.** Reset to defaults. Everything returns to a clean state and Wharf still runs.
- **O4.** Switch themes. Every dock on every display changes at once, within two seconds.
- **O5.** Switch profiles. Contents change per profile and switch back cleanly.
- **O6.** Set a per display override. It applies to that display only and no other.
- **O7.** Trigger an unread badge (send yourself a Mail message or a Slack DM). A badge with a count appears on the tile. Read the message and the badge clears.

## P. Performance and stability

These need Activity Monitor, in Applications, Utilities. Open it, search for "Wharf",
and read the Memory and %CPU columns. Numbers, not impressions.

- **P1.** Note Wharf's memory at launch. Leave it running 24 hours with normal use. Memory at the end is no more than double the starting figure, and not still climbing.
- **P2.** With previews off and the mouse still, Wharf's %CPU sits under 2% for a full minute.
- **P3.** Note the memory figure. Open and close 100 windows. Memory returns to within 20% of the starting figure within a minute of the last window closing, and no card is left over.
- **P4.** Unplug and replug a display ten times in a row. No crash, no duplicate docks, no dock left on a display that is gone.
- **P5.** Click a tile and watch how long until the window is in front. If you can perceive a delay, it fails.

## Q. Accessibility of the app itself

- **Q1.** Turn on VoiceOver. It reads each tile's app name and whether it is running.
- **Q2.** Reach and trigger every dock action using the keyboard alone.
- **Q3.** Turn on Reduce Motion. Sliding and scaling animations stop.
- **Q4.** Turn on Increase Contrast. The dock respects it.
- **Q5.** Raise the system text size. Labels and tooltips scale with it.

## R. First run

- **R1.** On a Mac that has never run Wharf, launch it for the first time. Within sixty seconds, without reading any documentation, you have a working dock on every display.
- **R2.** The first run explains what it is about to do to the system Dock before doing it.
- **R3.** There is an obvious way to undo everything and get back to a stock Mac.
