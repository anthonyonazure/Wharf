#!/bin/sh
# Compiles the window snapping geometry with its standalone checks and runs
# them. The Xcode project has no test target; this needs only the Swift
# toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-snap-geometry-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/WindowSnapGeometry.swift" \
    "$ROOT/Tests/WindowSnap/WindowSnapGeometryTests.swift" \
    -o "$OUT"
"$OUT"
