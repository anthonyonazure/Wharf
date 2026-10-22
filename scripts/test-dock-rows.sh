#!/bin/sh
# Compiles the multi-row dock arithmetic with its standalone checks and runs
# them. Needs only the Swift toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-dock-rows-tests"

xcrun swiftc -O -parse-as-library \
    "$ROOT/Docky/Services/DockRowLayout.swift" \
    "$ROOT/Tests/DockRows/DockRowLayoutTests.swift" \
    -o "$OUT"
"$OUT"

# Every view that reads this dock's context through @EnvironmentObject needs the
# context injected where it is built. The profile switcher lives in its own
# companion window, so each place it is built must call environmentObject(...)
# (a missing one crashed Wharf at launch: "No ObservableObject of type DockContext").
PS="$ROOT/Docky/Views/MainWindow/ProfileSwitcherWindowController.swift"
BUILT=$(grep -c 'ProfileSwitcherButtonView(' "$PS")
INJECTED=$(grep -c 'environmentObject(mainWindow.dockContext)' "$PS")
if [ "$BUILT" -ne "$INJECTED" ]; then
    echo "FAIL: ProfileSwitcherButtonView is built $BUILT times but the dock context is injected $INJECTED times"
    exit 1
fi
echo "PASS: profile switcher gets its dock context everywhere it is built"
