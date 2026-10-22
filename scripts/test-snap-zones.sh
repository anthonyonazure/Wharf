#!/bin/sh
# Compiles the drag-to-snap zone logic with its standalone checks and runs
# them. The zone logic uses WindowSnapAction, so the geometry file comes too.
# The Xcode project has no test target; this needs only the Swift toolchain
# that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-snap-zones-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/WindowSnapGeometry.swift" \
    "$ROOT/Docky/Services/WindowSnapDragZones.swift" \
    "$ROOT/Tests/WindowSnap/WindowSnapDragZonesTests.swift" \
    -o "$OUT"
"$OUT"
