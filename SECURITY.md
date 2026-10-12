# Security

## Reporting a problem

Please use GitHub's private vulnerability reporting for this repository
(Security tab, "Report a vulnerability") rather than opening a public issue.

## What Wharf can do on your Mac

Wharf replaces the system Dock. To do that it asks for **Accessibility** (to move
and read windows) and **Screen Recording** (to draw window previews), and it uses
private macOS interfaces. It does not need, and does not request, camera or
microphone access. It runs without the App Sandbox. Treat it like any other tool
that can see and move your windows: build it from source you have read, or wait
for a signed release.

## Threat model

The realistic attacker is another program already running as you. The things Wharf
trusts that such a program can change are the system Dock preferences, Wharf's own
preferences, window and app metadata exposed by other apps, files in folders the
dock displays, and third-party widget bundles. Wharf is meant to survive hostile
content in all of those without crashing, acting on the wrong app, or loading
unsigned code.

## Review history

| Date | Scope | Result |
| --- | --- | --- |
| 2026-09 | Run 1: URL scheme, widget loader, files, scripting, private APIs | One critical (a web page could install code through the widget loader), fixed by re-enabling library validation and removing quarantine stripping. Update feed removed because it pointed at a domain this fork does not own. |
| 2026-09 | Run 2: tile rendering, preference parsing, accessibility writes, capture | One high and several medium denial-of-service issues (a duplicate or out-of-range value in the Dock or Wharf preferences crashed the app on every launch). Fixed 2026-09-05. |
| 2026-10 | Run 3: the Audio widget and click-handling changes since run 2 | See the section below. |

## Known limitations

- Custom icon paths are read from wherever the preference points. A local program
  can make Wharf decode any file it can reach as an icon. The fix is to copy the
  chosen icon into an app-owned folder, which is a feature change and is tracked as
  open work.
- There is no auto-update channel. You update by building or downloading a new
  release.
- Wharf depends on private macOS interfaces that Apple can change in any release.

## Automated checks

Every change runs the unit test suite, a Release build and a secret scan
(`.github/workflows/test.yml`). The tests cover the parsers where past crashes lived.
