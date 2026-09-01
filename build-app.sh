#!/bin/bash
#
# Builds Nozzle.app — a normal, double-clickable macOS application.
#
# Swift Package Manager produces a bare executable, not an app bundle, so this
# script wraps it in the .app folder structure macOS expects.
#
#   ./build-app.sh            # release build (what you want day to day)
#   ./build-app.sh debug      # debug build
#
set -euo pipefail

CONFIGURATION="${1:-release}"
cd "$(dirname "$0")"

echo "Building Nozzle ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Nozzle

BIN_PATH="$(swift build -c "$CONFIGURATION" --product Nozzle --show-bin-path)"
APP="$PWD/Nozzle.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Nozzle" "$APP/Contents/MacOS/Nozzle"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Nozzle</string>
    <key>CFBundleDisplayName</key>          <string>Nozzle</string>
    <key>CFBundleExecutable</key>           <string>Nozzle</string>
    <key>CFBundleIdentifier</key>           <string>com.nozzle.Nozzle</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>0.1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <!-- Nozzle is intentionally NOT sandboxed: a sandboxed app cannot open
         /dev/cu.* without a provisioning profile from a paid developer account. -->
</dict>
</plist>
PLIST

# Ad-hoc signature. Without it macOS treats the bundle as damaged on some systems.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"

echo "Built $APP"
echo "Run it with:  open '$APP'"
