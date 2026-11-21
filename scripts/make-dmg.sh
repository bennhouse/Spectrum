#!/bin/zsh
# Builds Spectrum.app and packs it into build/Spectrum-<version>.dmg: a window with a background,
# Spectrum on the left and a shortcut to /Applications on the right. Apple Silicon only: the
# bundled ffmpeg and ffprobe are arm64 builds.
# Laying out the window uses Finder (AppleScript): macOS may ask once to allow it.
set -euo pipefail
cd "$(dirname "$0")/.."

NO_INSTALL=1 scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Spectrum-$VERSION.dmg"
VOL="Spectrum"

WORK=$(mktemp -d)
MNT=""
cleanup() {
    [[ -n "$MNT" ]] && hdiutil detach "$MNT" -quiet -force 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Background (1x + 2x in one TIFF) from scripts/make-dmg-background.swift
swiftc -O -o "$WORK/mkbg" scripts/make-dmg-background.swift
"$WORK/mkbg" "$WORK"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
cp -R build/Spectrum.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Writable image, laid out by Finder, then compressed.
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
MNT=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MNT"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$(basename "$MNT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Spectrum.app" of container window to {170, 180}
        set position of item "Applications" of container window to {470, 180}
        update without registering applications
        delay 2
        close
        -- Reopen and set the size again: Finder saves the window size to .DS_Store
        -- only after a close, and it can keep an older size the first time.
        open
        set bounds of container window to {200, 120, 840, 548}
        delay 2
        close
    end tell
end tell
APPLESCRIPT
sleep 2; sync
hdiutil detach "$MNT" -quiet
MNT=""

rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "Built $PWD/$DMG"
