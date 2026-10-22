#!/bin/sh
# Compiles the per-display override rules (lookup, fallback to the global
# setting, tolerant loading of stored values) with their standalone checks and
# runs them. Needs only the Swift toolchain that ships with Xcode.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wharf-perscreen-tests"

xcrun swiftc -O -parse-as-library \
    "$ROOT/Docky/Services/PerScreenResolution.swift" \
    "$ROOT/Tests/PerScreen/PerScreenResolutionTests.swift" \
    -o "$OUT"
"$OUT"
