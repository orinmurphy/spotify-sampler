#!/bin/zsh
# Builds SpotifySampler.app (ad-hoc signed) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SpotifySampler"

APP="SpotifySampler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpotifySampler"

# App icon: render artwork if missing, then build AppIcon.icns.
[[ -f Resources/icon-1024.png ]] || swift Scripts/make_icon.swift Resources/icon-1024.png
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Spotify Sampler</string>
    <key>CFBundleDisplayName</key><string>Spotify Sampler</string>
    <key>CFBundleIdentifier</key><string>local.spotifysampler</string>
    <key>CFBundleExecutable</key><string>SpotifySampler</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Spotify Sampler records Spotify's audio output so you can turn it into samples.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Spotify Sampler asks Spotify for the current track name to label your samples.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

# Install over the copy in /Applications (the one pinned in the Dock).
pkill -x SpotifySampler 2>/dev/null || true
rm -rf "/Applications/$APP"
ditto "$APP" "/Applications/$APP"
touch "/Applications/$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP" || true
echo "Installed /Applications/$APP"
