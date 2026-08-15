<div align="center">

# Wharf

### The dock that lives on every display.

Wharf is a macOS Dock replacement built for multi-monitor desks. macOS ships exactly
one Dock and it can only occupy one display at a time. Wharf puts a real dock on
every screen, at once, permanently.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/anthonyonazure/Wharf)
[![Universal](https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-Universal-orange)](https://github.com/anthonyonazure/Wharf)

</div>

## Why

Apple has never allowed the Dock to extend, mirror, or duplicate across displays.
On a three-monitor desk that means the Dock lives on one screen and you fetch it by
shoving the cursor at a screen edge and waiting. The commercial answers to this
(uBar, ExtraDock, Sidebar) are closed source and cost between $30 and $47.

Wharf is the open source answer, and it aims past parity rather than at it.

## Status

Early. Wharf is a hard fork of [Docky](https://github.com/josejuanqm/docky) and
currently builds and behaves as Docky does. The multi-display work described below
is in progress and not yet shipped. Do not treat this as a working product yet.

## Inherited from Docky

These already work, courtesy of upstream:

- **Tiles and layout** — apps, widgets, Smart Stacks, folders, spacers, dividers
- **Live window switcher** — Cmd-Tab style with live previews, plus per-tile hover previews
- **Launchpad** — fullscreen, searchable, keyboard navigable
- **Widgets** — Calendar, Reminders, Batteries, System, Weather, Now Playing, stackable
- **Rich app folders** — nested navigation, Quick Look, drag and drop
- **Custom app icons**, **scripted actions**, **themes and profiles**
- Universal binary, notarized, Sparkle auto-updates

## Roadmap

### 1. Multi-display (the reason this fork exists)

- [x] One dock instance per screen instead of a single shared window
- [x] Mirror mode: identical dock on every display
- [x] Docks pinned to a specific display, surviving unplug and reconnect
- [x] Per-screen mode: each dock shows only the windows on its own screen
- [ ] Per-screen configuration (position, theme, size, contents)

Turn it on in **Settings → Behavior → Placement → Display → All Displays**.

### 1b. Windows keyboard mode

- [x] Ctrl+C/V/X/Z and the rest of the editing set behave as they do on Windows
- [x] Terminals excluded, so Ctrl+C there still sends SIGINT
- [x] Win+Shift+S draws a region straight to the clipboard, like the Windows snip
- [ ] Per-app override UI (the exclusion list is editable via defaults today)
- [ ] Win key opens the Launchpad / start menu

In **Settings → Behavior → Windows Keyboard**. Needs Accessibility permission.

### 2. Taskbar mode

- [x] Per-window cards rather than per-app icons
- [x] Single-window apps stay collapsed as icons; multi-window apps expand
- [x] Window grouping: always, never, automatic

### 3. Status and awareness

- [x] Notification badges (inherited)
- [x] Launching and unresponsive state indicators
- [x] Media track progress on media app tiles
- [x] CPU and RAM readout on Control hold
- [~] Attention flashing — the tile animation is built, but macOS exposes no
  public signal for another process calling `requestUserAttention`, so nothing
  currently triggers it except the internal entry point

### 4. Placement and behavior

- [x] Any screen edge (global today, not yet per display)
- [x] Windows respect dock edges without overlapping, on every screen
- [x] Collapse to a single button
- [~] Multi-row layouts — rows are built and chunked, but the dock chrome is
  still sized for one row, so extra rows are clipped. Needs the chrome
  measurement to account for row count
- [ ] Float or snap, per dock
- [ ] Blink-free native fullscreen transitions
- [ ] Native Dock suppression control

## Building from source

```sh
git clone https://github.com/anthonyonazure/Wharf.git
cd Wharf
open Docky.xcodeproj
```

Build and run the `Docky` scheme. Swift Package dependencies (Sparkle) resolve on
first build. The Xcode target is still named `Docky`; renaming it is tracked as its
own task so that merges from upstream stay clean in the meantime.

### Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16 or later

Wharf needs **Accessibility** and **Screen Recording** permissions to manage windows
and render previews, and prompts on first launch.

> [!NOTE]
> Wharf inherits Docky's use of private SkyLight / CoreGraphics Services and
> Accessibility SPI (see `Docky/Private/`) to position windows, capture previews and
> drive the system Dock. Because of this it **cannot be distributed on the Mac App
> Store**. It is built from source or distributed directly.

## Relationship to upstream

Wharf keeps Docky's full commit history and tracks it as a git remote, so upstream
fixes can be merged rather than reimplemented:

```sh
git fetch upstream
git merge upstream/main
```

## Credits and license

Wharf is a fork of **[Docky](https://github.com/josejuanqm/docky)** by
**Jose Quintero**, licensed GPL-3.0. All of Docky's original copyright notices are
preserved. Enormous credit to Jose for building the foundation this stands on; if
Wharf is useful to you, consider [sponsoring the upstream
project](https://github.com/sponsors/josejuanqm).

Some planned behavior is informed by
**[Tungsten Edge](https://github.com/moonbai-studio/tungsten-edge)** (also GPL-3.0),
which solved per-window taskbar cards and blink-free fullscreen transitions.

Licensed under the [GNU General Public License v3.0](LICENSE). Because Wharf derives
from GPL-3.0 code, it and any distributed derivative must remain open source under
the same license.

Copyright (C) 2026 Jose Quintero (original Docky work)
Copyright (C) 2026 Anthony Clendenen (Wharf modifications)
