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
