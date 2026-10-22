#!/bin/sh
# Compiles the Command Bar's pure logic (calculator, unit conversion,
# ranking, strict number parsing, query limits, destructive command
# classification, stable selection, history validation and the file result
# filter) with its standalone checks and runs them. The checks include
# hostile input such as 1/0, huge exponents and thousands of open brackets;
# a watchdog inside the test fails the run if anything hangs. Needs only the
# Swift toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-command-bar-tests"

xcrun swiftc -O \
    "$ROOT/Docky/Services/CommandBarCore.swift" \
    "$ROOT/Docky/Services/WindowSnapGeometry.swift" \
    "$ROOT/Tests/CommandBar/CommandBarCoreTests.swift" \
    -o "$OUT"
"$OUT"
