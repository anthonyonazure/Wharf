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
echo "PASS: service source guards"
