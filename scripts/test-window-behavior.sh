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
