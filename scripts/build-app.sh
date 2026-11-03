#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Deltarune Mod Manager.app"
ICONSET="$ROOT/.build/AppIcon-UserAsset.iconset"
ICON_PNG="$ROOT/Sources/DeltaruneModManager/Resources/app-icon.png"

cd "$ROOT"
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp "$ROOT/.build/release/DeltaruneModManager" "$APP/Contents/MacOS/DeltaruneModManager"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/DeltaruneModManager/Resources/title-background.png" \
    "$APP/Contents/Resources/title-background.png"
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
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
