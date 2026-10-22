#!/bin/sh
# Compiles the focus follows mouse, Spaces order and Win key tap logic with its
# standalone checks and runs them. The Xcode project has no test target; this
# needs only the Swift toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-focus-and-wintap-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/FocusAndWinTapLogic.swift" \
    "$ROOT/Tests/FocusAndWinTap/FocusAndWinTapTests.swift" \
    -o "$OUT"
"$OUT"

# Code review chunk 2 safety checks (focus follows mouse, fixed Space order).
xcrun swiftc -O \
    "$ROOT/Docky/Services/FocusAndWinTapLogic.swift" \
    "$ROOT/Docky/Services/FocusAndSpacesSafetyLogic.swift" \
    "$ROOT/Tests/FocusAndWinTap/FocusSpacesSafetyTests.swift" \
    -o "$OUT-safety"
"$OUT-safety"
