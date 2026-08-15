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

## Deviations

_(none yet)_
