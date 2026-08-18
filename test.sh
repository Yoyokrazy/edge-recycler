#!/bin/bash
# Run the EdgeRecyclerCore unit tests. Compiles the pure-logic core together
# with the dependency-free test runner into a throwaway binary and executes it.
# No XCTest or SwiftPM — same simple swiftc toolchain as build.sh. Exits non-zero
# if any check fails, so it can gate CI.
set -euo pipefail

cd "$(dirname "$0")"
BIN="${TMPDIR:-/tmp}/EdgeRecyclerCoreTests"

echo "==> Compiling tests" >&2
swiftc -swift-version 5 \
    -o "$BIN" \
    Sources/EdgeRecyclerCore.swift Tests/CoreTests.swift

echo "==> Running tests" >&2
"$BIN"
