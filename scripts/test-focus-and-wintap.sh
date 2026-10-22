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
