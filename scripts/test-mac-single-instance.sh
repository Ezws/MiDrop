#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/single-instance-test"
mkdir -p "$BUILD"
swiftc -O -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/SingleInstanceLock.swift" "$ROOT/tests/mac-single-instance/main.swift" -o "$BUILD/test-instance"
"$BUILD/test-instance"
