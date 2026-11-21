#!/bin/zsh
# Builds Spectrum with SwiftPM, assembles build/Spectrum.app with the decoder inside
# (Contents/Resources/bin: a minimal ffmpeg and ffprobe), signs it, installs it in /Applications
# (replacing the copy there) and launches it.
#   scripts/build-app.sh               build, sign, install
#   NO_INSTALL=1 scripts/build-app.sh  only build/Spectrum.app
#
# The tools come from vendor/bin; scripts/fetch-tools.sh builds them when missing.
# Signing uses the local identity in signing/ (scripts/setup-signing.sh creates it), so macOS
# keeps folder permissions across rebuilds. ADHOC=1 signs ad hoc instead.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -x vendor/bin/ffmpeg && -x vendor/bin/ffprobe ]] || scripts/fetch-tools.sh
if [[ ! -f Resources/AppIcon.icns ]]; then
    WORK=$(mktemp -d)
    swift scripts/make-icon.swift "$WORK"
    iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
    cp "$WORK/icon-preview.png" Resources/icon-preview.png
    rm -rf "$WORK"
fi

swift build -c release
APP="build/Spectrum.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spectrum "$APP/Contents/MacOS/Spectrum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
ditto vendor/bin "$APP/Contents/Resources/bin"

ID="local.spectrum.Spectrum"
KC="$PWD/signing/spectrum.keychain-db"
# Every executable and library inside bin is signed first, then the app around them.
sign_all() {   # codesign options...
    find "$APP/Contents/Resources/bin" -type f | while read -r f; do
        if file -b "$f" | grep -q 'Mach-O'; then codesign --force "$@" "$f"; fi
    done
    codesign --force "$@" --identifier "$ID" "$APP"
}
if [[ "${ADHOC:-0}" == "1" ]]; then
    sign_all --sign -
elif [[ -f "$KC" ]]; then
    security unlock-keychain -p spectrum "$KC"
    # codesign only finds identities in keychains on the search list: add ours for the duration.
    OLD=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
    security list-keychains -d user -s "${OLD[@]}" "$KC"
    sign_all --keychain "$KC" --sign "Spectrum Local Signing" || STATUS=$?
    security list-keychains -d user -s "${OLD[@]}"
    [[ -z "${STATUS:-}" ]] || exit $STATUS
else
    echo "error: signing/spectrum.keychain-db not found. Run scripts/setup-signing.sh, or ADHOC=1." >&2
    exit 1
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

if [[ "${NO_INSTALL:-0}" != "1" ]]; then
    osascript -e 'tell application id "local.spectrum.Spectrum" to quit' 2>/dev/null || true
    rm -rf "/Applications/Spectrum.app"
    ditto "$APP" "/Applications/Spectrum.app"
    open "/Applications/Spectrum.app"
    echo "Installed and launched /Applications/Spectrum.app"
else
    echo "Built $PWD/$APP"
fi
