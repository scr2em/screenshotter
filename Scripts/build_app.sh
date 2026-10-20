#!/bin/bash
# Builds Screenshotter.app into ./build.
#   Scripts/build_app.sh                  # this Mac's architecture
#   Scripts/build_app.sh --universal      # arm64 + x86_64 (used for releases)
#   SIGN_IDENTITY=- Scripts/build_app.sh  # ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Screenshotter.app"
UNIVERSAL=false
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=true

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift Scripts/make_icon.swift Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if $UNIVERSAL; then
    # Swift 6.4+ writes every triple's products to the same folder, so keep each slice aside before the next build.
    SLICES=".build/universal-slices"
    rm -rf "$SLICES"
    mkdir -p "$SLICES"
    for TRIPLE in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        swift build -c "$CONFIG" --triple "$TRIPLE"
        cp "$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/Screenshotter" "$SLICES/Screenshotter-$TRIPLE"
    done
    lipo -create "$SLICES"/Screenshotter-* -output "$APP/Contents/MacOS/Screenshotter"
else
    swift build -c "$CONFIG"
    cp "$(swift build -c "$CONFIG" --show-bin-path)/Screenshotter" "$APP/Contents/MacOS/Screenshotter"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording permission valid across rebuilds.
# Ad-hoc signatures change on every build, so macOS would ask again each time.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Screenshotter"), signed with: $SIGN_IDENTITY)"
