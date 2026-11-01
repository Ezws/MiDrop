#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MIDROP_APP_OUTPUT:-$PROJECT_ROOT/dist/MiDrop.app}"
BUILD="$PROJECT_ROOT/.build/share-test"
mkdir -p "$BUILD"
swiftc -O -module-cache-path "$PROJECT_ROOT/.build/module-cache" \
  "$PROJECT_ROOT/tests/mac-share/main.swift" -o "$BUILD/test-share" -framework AppKit
"$BUILD/test-share" "$APP"
