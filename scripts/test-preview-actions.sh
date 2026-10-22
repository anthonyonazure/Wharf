#!/bin/sh
# Compiles the Preview Actions and dock Layouts menu logic with its standalone
# checks and runs them. The snap geometry file is included because the logic
# names snap actions. Needs only the Swift toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-preview-actions-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/WindowSnapGeometry.swift" \
    "$ROOT/Docky/Services/PreviewActionsLogic.swift" \
    "$ROOT/Tests/PreviewActions/PreviewActionsLogicTests.swift" \
    -o "$OUT"
"$OUT"
