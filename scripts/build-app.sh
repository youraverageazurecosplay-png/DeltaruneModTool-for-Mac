#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Deltarune Mod Manager.app"

cd "$ROOT"
swift build -c release
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/DeltaruneModManager" "$APP/Contents/MacOS/DeltaruneModManager"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DELTARUNE Mod Manager</string>
    <key>CFBundleDisplayName</key>
    <string>DELTARUNE Mod Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.deltarune-mod-manager</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleExecutable</key>
    <string>DeltaruneModManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
printf 'Built: %s\n' "$APP"
