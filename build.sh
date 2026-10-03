#!/bin/sh
set -eu
cd "$(dirname "$0")"

architecture="${1:-universal}"
case "$architecture" in
    arm64|x86_64|universal) ;;
    *) printf 'Usage: %s [arm64|x86_64|universal]\n' "$0" >&2; exit 2 ;;
esac

app="build/$architecture/Console View.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary="$app/Contents/MacOS/consoleview"

if [ "$architecture" = universal ]; then
    ./build.sh arm64
    ./build.sh x86_64
    xcrun lipo -create \
        "build/arm64/Console View.app/Contents/MacOS/consoleview" \
        "build/x86_64/Console View.app/Contents/MacOS/consoleview" \
        -output "$binary"
else
    xcrun swiftc -sdk "$(xcrun --show-sdk-path)" \
        -target "$architecture-apple-macos14.0" \
        -swift-version 5 -parse-as-library -O -whole-module-optimization \
        -framework AppKit -framework SwiftUI -framework AVFoundation \
        -framework CoreMedia Sources/*.swift -o "$binary"
fi

cp Info.plist "$app/Contents/Info.plist"
cp icon/PS4View.icns "$app/Contents/Resources/PS4View.icns"
cp icon/icon_1024.png "$app/Contents/Resources/AppIcon.png"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD-PARTY-NOTICES.md "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
xcrun lipo -info "$binary"
printf 'Built %s (ad-hoc signed; not notarized)\n' "$app"
