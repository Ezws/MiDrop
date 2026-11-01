#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/board-model-test"
mkdir -p "$BUILD"
cp "$ROOT/mac/receiver.py" "$BUILD/receiver.py"
swiftc -O -D MIDROP_MODEL_TESTS -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/mac/MiDrop.swift" "$ROOT/mac/TextSharing.swift" "$ROOT/mac/StateDirectoryMonitor.swift" "$ROOT/mac/SingleInstanceLock.swift" \
  "$ROOT/tests/mac-board/main.swift" -o "$BUILD/test-board" -framework SwiftUI -framework AppKit
"$BUILD/test-board"
