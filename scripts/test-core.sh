#!/usr/bin/env bash
# Builds the engine's test runner with swiftc over Core/*.swift and runs it against the fixtures in e2e/fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)/core-tests"
swiftc -O -swift-version 5 "$ROOT"/Core/*.swift "$ROOT"/Tests/main.swift -o "$BIN" -framework WebKit -framework AVFoundation -framework CoreImage
"$BIN" "$ROOT"
