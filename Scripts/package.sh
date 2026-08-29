#!/bin/zsh
# Builds dist/Ladder.app from the release binary, with icon and ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
    mkdir -p Resources
    swift Scripts/make-icon.swift Resources
fi

APP=dist/Ladder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LadderApp "$APP/Contents/MacOS/LadderApp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LadderApp</string>
    <key>CFBundleIdentifier</key><string>com.jtmaher.ladder</string>
    <key>CFBundleName</key><string>Ladder</string>
    <key>CFBundleDisplayName</key><string>Ladder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "packaged $APP"
