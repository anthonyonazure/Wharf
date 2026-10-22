#!/bin/sh
# Compiles the Window Behavior logic with its standalone checks and runs
# them. The Xcode project has no test target; this needs only the Swift
# toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-window-behavior-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/WindowBehaviorLogic.swift" \
    "$ROOT/Tests/WindowBehavior/WindowBehaviorLogicTests.swift" \
    -o "$OUT"
"$OUT"

# The chunk 1 code review fixes for quit protection and quit on close, as
# their own program.
xcrun swiftc -O \
    "$ROOT/Docky/Services/WindowBehaviorLogic.swift" \
    "$ROOT/Tests/WindowBehavior/QuitGuardReviewTests.swift" \
    -o "$OUT-quit-review"
"$OUT-quit-review"

# Source guards for the review fixes that live in the services, not the
# pure logic. Quit protection must never post a shortcut to whatever app is
# in front (only postToPid to the captured app), and must sit at the tail of
# the session taps so Windows keyboard translation runs first.
GUARD="$ROOT/Docky/Services/QuitGuardService.swift"
if grep -n 'post(tap:' "$GUARD"; then
    echo "FAIL: QuitGuardService posts a global event"
    exit 1
fi
grep -q 'place: .tailAppendEventTap' "$GUARD" || { echo "FAIL: QuitGuardService tap is not tail appended"; exit 1; }
# The green button tap must not ask Accessibility while deciding.
GREEN="$ROOT/Docky/Services/GreenButtonMaximizeService.swift"
awk '/private func handle\(type:/,/MARK: - Looking the button up/' "$GREEN" > "$OUT.handle"
if grep -n 'AXUIElement' "$OUT.handle"; then
    echo "FAIL: the green button tap path calls Accessibility"
    exit 1
fi
# A timeout set on the system wide element changes the default for every
# element in Wharf, so the green button must not touch that element at all.
if grep -n 'AXUIElementCreateSystemWide' "$GREEN"; then
    echo "FAIL: the green button uses the system wide Accessibility element"
    exit 1
fi
# A click the green button held back must go back to the app when Wharf does
# nothing with it: every give-up path calls replay.
REPLAYS=$(grep -c 'replay(click, release: release)' "$GREEN")
if [ "$REPLAYS" -lt 5 ]; then
    echo "FAIL: expected the held click to be replayed on every give-up path, found $REPLAYS"
    exit 1
fi
# Chunk 1 review fixes in the quit services: the hold rechecks the physical
# key, a dead tap is noticed and rebuilt, the focus owner is checked, the
# HUD text wraps, and start() runs once.
grep -q 'CGEventSource.keyState' "$GUARD" || { echo "FAIL: the hold does not recheck the key"; exit 1; }
grep -q 'CGEvent.tapIsEnabled' "$GUARD" || { echo "FAIL: a dead quit protection tap is not noticed"; exit 1; }
grep -q 'AXUIElementCreateSystemWide' "$GUARD" || { echo "FAIL: quit protection does not check the focus owner"; exit 1; }
if grep -n 'lineLimit(1)' "$GUARD"; then
    echo "FAIL: the HUD clips long app names"
    exit 1
fi
# Chunk 1 re-check: a timeout on the system wide element changes it for all
# of Wharf; a Command-W whose effect cannot be seen is never called a
# failure; the key-up of a long held key still reaches the machine; quit on
# close never re-arms on a modal dialog.
if grep -n 'SetMessagingTimeout(system' "$GUARD"; then
    echo "FAIL: quit protection sets a timeout on the system wide element"
    exit 1
fi
if grep -n 'could not confirm' "$GUARD"; then
    echo "FAIL: quit protection reports an unseen Command-W as a failure"
    exit 1
fi
grep -q 'machine.remembers(keyCode: keyCode)' "$GUARD" || { echo "FAIL: a quiet owned key is not routed to the machine"; exit 1; }
grep -q 'kAXModalAttribute' "$ROOT/Docky/Services/QuitOnCloseService.swift" || { echo "FAIL: quit on close does not read the modal flag"; exit 1; }
grep -q 'Quit and Keep Windows' "$ROOT/Docky/Views/SettingsWindow/WindowBehaviorSettingsView.swift" || { echo "FAIL: the settings text does not name Quit and Keep Windows"; exit 1; }
for SERVICE in "$GUARD" "$ROOT/Docky/Services/QuitOnCloseService.swift"; do
    grep -q 'guard !started else { return }' "$SERVICE" || { echo "FAIL: start() is not idempotent in $SERVICE"; exit 1; }
done
echo "PASS: service source guards"
