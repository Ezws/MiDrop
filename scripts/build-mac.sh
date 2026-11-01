#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MIDROP_APP_OUTPUT:-$PROJECT_ROOT/dist/MiDrop.app}"
EXTENSION="$APP/Contents/PlugIns/MiDropShare.appex"
if [[ ! -f "$PROJECT_ROOT/assets/MiDrop.icns" ]]; then bash "$PROJECT_ROOT/scripts/build-icons.sh"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_ROOT/.build/module-cache"
swiftc -O -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PROJECT_ROOT/.build/module-cache" \
  "$PROJECT_ROOT/mac/MiDrop.swift" "$PROJECT_ROOT/mac/TextSharing.swift" "$PROJECT_ROOT/mac/StateDirectoryMonitor.swift" "$PROJECT_ROOT/mac/SingleInstanceLock.swift" -o "$APP/Contents/MacOS/MiDrop" -framework SwiftUI -framework AppKit
cp "$PROJECT_ROOT/mac/receiver.py" "$APP/Contents/Resources/receiver.py"
cp "$PROJECT_ROOT/assets/MiDrop.icns" "$APP/Contents/Resources/MiDrop.icns"
mkdir -p "$EXTENSION/Contents/MacOS" "$EXTENSION/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PROJECT_ROOT/.build/module-cache" \
  -parse-as-library -application-extension -module-name MiDropShare \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$PROJECT_ROOT/mac/ShareExtension/ShareViewController.swift" \
  -o "$EXTENSION/Contents/MacOS/MiDropShare" -framework AppKit
cp "$PROJECT_ROOT/mac/ShareExtension/Info.plist" "$EXTENSION/Contents/Info.plist"
cp "$PROJECT_ROOT/assets/MiDrop.icns" "$EXTENSION/Contents/Resources/MiDrop.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.midrop.mac</string>
<key>CFBundleName</key><string>MiDrop</string>
<key>CFBundleExecutable</key><string>MiDrop</string>
<key>CFBundleIconFile</key><string>MiDrop.icns</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.midrop.mac.text</string>
<key>CFBundleURLSchemes</key><array><string>midrop</string></array>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>要发送的文件</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>None</string>
<key>LSItemContentTypes</key><array><string>public.data</string></array>
</dict></array>
<key>LSUIElement</key><true/>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocalNetworkUsageDescription</key><string>发现小米手机并接收局域网内发送的照片和文件。</string>
<key>NSBonjourServices</key><array><string>_midrop._tcp</string></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$PROJECT_ROOT/mac/ShareExtension/ShareExtension.entitlements" "$EXTENSION"
codesign --force --sign - "$APP"
echo "已生成：$APP"
