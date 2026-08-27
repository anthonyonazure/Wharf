# Handoff

## Where this stands

Wharf is a macOS Dock replacement, hard-forked from
[Docky](https://github.com/josejuanqm/docky) (GPL-3.0) on 2026-08-15 because macOS
allows exactly one Dock on one display and no open-source project did per-display
docks. It now builds and installs as `Wharf.app`, runs on a three-display desk with
a dock on every screen, and carries features that exist nowhere upstream:
taskbar mode with per-window cards, a Windows-keyboard translation layer, saved
window layouts with rules that fire them automatically, and window management from
the tile right-click menu. Everything is committed and pushed; the tree is clean.
The one thing blocking a feature right now is a macOS permission, not code: the
bundle identifier changed, so Accessibility must be re-granted to `Wharf.app`
before keyboard translation and window moving work again.

## Verified

Run at handoff time, in `/Users/anthony/projects/wharf`:

- `git status --short` → empty. Clean tree.
- `git branch --show-current` → `main`.
- `git rev-list --left-right --count origin/main...HEAD` → `0 0`. Nothing unpushed.
- `git stash list` → empty.
- `xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug build`
  → `** BUILD SUCCEEDED **`, zero errors.
- Product identity: `Wharf.app`, `CFBundleName = Wharf`,
  `CFBundleIdentifier = com.anthonyonazure.Wharf`.
- App is running: `/Applications/Wharf.app/Contents/MacOS/Wharf` (pid alive at
  handoff, stable past 26s).
- Menu bar item reads "Wharf" (confirmed by screenshot, not by reading code).
- Preferences survived the rename: `docky.windowDisplayTarget = allDisplays`,
  `wharf.dockContentMode = dock`, `wharf.windowGrouping = always`,
  `wharf.windowsKeyboardMode = true`.
- Saved layout `TestLayout` (38 windows) still present in the Wharf domain.
- Earlier in the session, layout restore was proven end to end: a window was
  moved to `150,300` and restored to `1899, 94, 700, 500`, exact position and size.

## Unverified

- **No test suite exists.** `ls Tests` finds nothing, and the project has no test
  scheme (`xcodebuild -list` shows only `Docky` and `DockyDockWatchdog`). Every
  behavioral claim in this repo was proven by running the app and reading
  screenshots, never by an automated test. Treat all of it as manually verified,
  and re-verify by hand after changes.
- Layout **rules** (`LayoutTriggerEngine`) are built, wired and shipped, but no rule
  has ever actually fired. `wharf.layoutRules` is empty. The engine, its settings
  pane and its persistence compile and load; the firing path is unproven at runtime.
- The clock widget's calendar glow has never been seen with a real event
  approaching. The maths and the build are verified; the visual is not.
- Right-click actions (fullscreen, size lock, close all, quit, force quit, hide)
  compile and appear in the menu construction code. None was clicked and observed.
- Multi-row layout renders and is measured row-aware, but a screenshot of a real
  two-row dock was never captured cleanly.

## Disagreements found while writing this

- **I believed Accessibility was granted; it is not.** The status file at
  `/Users/anthony/Library/Application Support/Docky/wharf-keyboard-status.txt`
  currently reads `BLOCKED: Accessibility not granted to this build`. Renaming the
  bundle identifier to `com.anthonyonazure.Wharf` invalidated the grant, exactly as
  predicted but not confirmed until now. Windows-keyboard translation and every
  window move (including layout restore) are inert until it is re-granted.
- **The old app was not removed.** `/Applications/Docky.app` still exists. A guard
  blocked deleting it, correctly, so it was left for Anthony. It is inert and
  shares nothing with Wharf (separate bundle id, preferences and permissions).

## Repository state

- Branch `main`, clean, fully pushed to `origin`
  (`https://github.com/anthonyonazure/Wharf.git`).
- `upstream` remote points at `josejuanqm/docky` for merging their fixes:
  `git fetch upstream && git merge upstream/main`.
- Full 310-commit upstream history is preserved beneath the fork's own commits.
- Latest commit: `b1bd355 Ship as Wharf: rename the product, not just the repo`.

## Next action

Grant Accessibility to `Wharf.app`, then prove the layout-rule path end to end,
which is the one shipped feature that has never actually run:

1. System Settings → Privacy & Security → Accessibility → enable **Wharf**
   (the menu bar item shows the blocked state and links straight there).
2. Confirm the status file flips to `ACTIVE`.
3. Settings → Layout Rules → add a rule firing `TestLayout` at a time two minutes
   out, then watch whether windows actually move at that minute.

If they do not move, the suspect is `LayoutTriggerEngine.evaluateTimeAndCalendarRules`,
whose 20-second timer must land inside the target minute.

## Traps

- **Rebuilding does not update what you run.** The app installs to
  `/Applications/Wharf.app`; `xcodebuild` only writes to DerivedData. After every
  build run
  `ditto <DerivedData>/Build/Products/Debug/Wharf.app /Applications/Wharf.app`.
  Skipping this means testing a stale binary, which cost a long detour once already.
- **`shasum` on the executable lies in Debug builds.** `Contents/MacOS/Wharf` is a
  ~40 KB stub; the real code sits beside it in `Wharf.debug.dylib`. Compare the
  dylib's timestamp, never the stub's hash.
- **Every rebuild can invalidate Accessibility**, because the ad-hoc signature
  changes. System Settings will still show the toggle on while the app is denied.
  The app writes the truth to
  `~/Library/Application Support/Docky/wharf-keyboard-status.txt` (ACTIVE / BLOCKED
  / OFF) — read that file rather than trusting the toggle.
- **`nm` and `strings` on the linked binary find nothing.** Swift internals are
  stripped from the export table and `String(localized:)` text lives in the string
  catalog. To prove a file compiled, check `Docky.SwiftFileList` and its `.o`.
- **AppleScript keystrokes cannot test the event tap.** They enter downstream of a
  session tap. Post at the HID tap point instead
  (`CGEvent.post(tap: .cghidEventTap)`).
- **Window placement must be applied twice.** AX sets position then size, and a
  window carrying its old size gets its move clamped: the resize lands, the move
  silently does not.
- **Do not rename the Xcode target or internal types** (`DockyPreferences`,
  `DockyGlass`). Only the product name, bundle id and `String(localized:)` contents
  are Wharf, deliberately, so upstream merges stay clean. `docky://` URLs still work
  alongside `wharf://`.
- **The Sparkle update feed is deliberately removed.** Restoring upstream's appcast
  would auto-update Wharf into Docky and erase the fork.
- **Gemini fabricates on repeat runs.** Its first and third review rounds were
  accurate; its second invented 13 findings citing symbols that do not exist and
  line numbers past end of file. Verify every finding against the real file before
  acting on it.

---

## Checkpoint 2026-08-27: the dock click

Everything below was measured on Anthony's live three-display desk, not reasoned about.

### Fixed and verified

- **Signing.** `DEVELOPMENT_TEAM` was upstream Docky's, so builds fell back to ad-hoc
  and macOS pinned permission grants to the binary's hash, losing them on every
  rebuild. Team is now the certificate's real OU (`4P54C2K45P`). Grants survive.
- **Idle CPU: 21.6% of a core to about 0.3%.** One tile pulsed with a `repeatForever`
  animation, and a SwiftUI animation that never ends redraws every dock at the display
  refresh rate forever. The flag that started it was set at launch for every app that
  already had a badge, and only cleared on activation, which for System Settings never
  happens. Three fixes: seed the badge map on first scan, expire attention after six
  seconds, bound the pulse.
- **Two accessibility pollers** that ran every two seconds forever now batch, back off,
  and stop while the screen is locked. Real but not the CPU cause.
- **Hover preview** was a plain NSWindow and could bring Wharf forward, which broke the
  frontmost-tracked tile click. Now a non-activating panel.
- **Activation** used `NSRunningApplication.activate()`, which macOS 14+ may ignore when
  the caller is never the active app. Now yields activation first. Of clicks that
  reached the handler, raises went from 8/14 to 11/13.

### Still broken: the click

Two layers, both pointing at the container's reorder `DragGesture`.

1. **The mouse-up is sometimes never delivered.** Nineteen HID-posted presses produced
   seventeen releases. Nothing built on press-and-release survives this. Prime suspect:
   the drag gesture entering an event-tracking loop that consumes the release.
2. **The tap gesture drops about half of the releases that do arrive**, losing an
   arbitration with that same drag. Traced: every click reached the dock window, the
   correct tile was identified every time, the handler ran half the time.

Investigate the reorder gesture first. It is one cause, not two.

### Approaches already tried and reverted, with the reason

- Raising the reorder threshold (4 to 10): no effect on delivery.
- A zero-distance drag gesture on the tile: loses the same arbitration.
- Taking the click from `TilePressService`'s AppKit monitor, identified by hover:
  delivery rose to ~3/4, but hover lags the pointer, so clicking while moving acted on
  the icon just passed. A wrong app is worse than no app.
- The same, narrowed to only the 5-to-10 point band: inherits the hover problem.
- Hit-testing the press against the container's published tile frames: **this is the
  right answer.** The frames arrive correctly (33 per dock window, window coordinates,
  origin top-left) and the press converts cleanly, but matching was not stable across
  runs. Finish this.

### Traps in measuring this

- **`cliclick` loses events against this app.** Post at the HID tap point with CGEvent
  instead. `clicker.swift` and `movingclick.swift` in the session scratchpad do it.
  The repo already said this for keyboard input; it applies to the mouse too.
- **Tile coordinates drift** whenever dock contents change, and clicking a tile edge is
  unreliable. Re-derive the centre from a fresh screenshot every run.
- **Never test on the Finder tile**: it opens a folder popover on hover that eats the
  next click.
- **Take tile identity from the app's own hover log, never from the icon.** The test
  dock had two Firefox tiles that render identically, one pinned and one a folder child.
- Verify the instrument before trusting a result. Most of 2026-08-27 was spent acting on
  numbers from a rig that was wrong in four separate ways.
