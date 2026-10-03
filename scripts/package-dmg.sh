#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

architecture="${1:-all}"
case "$architecture" in
    all) ./scripts/package-dmg.sh arm64; ./scripts/package-dmg.sh x86_64; exit 0 ;;
    arm64) label="Apple-Silicon" ;;
    x86_64) label="Intel" ;;
    *) printf 'Usage: %s [arm64|x86_64|all]\n' "$0" >&2; exit 2 ;;
esac

dmg_python="${DMG_PYTHON:-python3}"
if ! "$dmg_python" -c 'import ds_store, mac_alias' 2>/dev/null; then
    printf 'Install scripts/dmg-requirements.txt in a local venv and set DMG_PYTHON to its Python executable.\n' >&2
    exit 1
fi

app="build/$architecture/Console View.app"
binary="$app/Contents/MacOS/consoleview"
if [ ! -f "$binary" ]; then
    printf 'Build the app first with ./build.sh %s\n' "$architecture" >&2
    exit 1
fi
xcrun lipo -verify_arch "$architecture" "$binary"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
mkdir -p build dist
stage=$(mktemp -d "build/dmg-$architecture.XXXXXX")
payload="$stage/payload"
mount_dir=""
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$mount_dir" >/dev/null 2>&1 || return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$payload"
ditto "$app" "$payload/Console View.app"
ln -s /Applications "$payload/Applications"
cp "$app/Contents/Resources/LICENSE.txt" "$payload/LICENSE.txt"
cp "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt" "$payload/THIRD-PARTY-NOTICES.txt"
cp icon/PS4View.icns "$payload/.VolumeIcon.icns"
mkdir "$payload/.background"
cp packaging/macos/background.tiff "$payload/.background/background.tiff"
image="dist/Console-View-$version-$label.dmg"
writable="$stage/installer.dmg"
hdiutil create -volname "Console View" -fs HFS+ -srcfolder "$payload" -format UDRW -ov "$writable"
hdiutil attach -nobrowse -noautoopen -mountrandom /Volumes -plist "$writable" > "$stage/mount.plist"
mount_dir=$("$dmg_python" -c 'import plistlib, sys; data = plistlib.load(open(sys.argv[1], "rb")); print(next(item["mount-point"] for item in data["system-entities"] if "mount-point" in item))' "$stage/mount.plist")
mounted=true
xcrun SetFile -a C "$mount_dir"
chflags hidden "$mount_dir/LICENSE.txt" "$mount_dir/THIRD-PARTY-NOTICES.txt"
"$dmg_python" scripts/dmg-layout.py "$mount_dir"
hdiutil detach "$mount_dir"
mounted=false
hdiutil convert "$writable" -format UDZO -imagekey zlib-level=9 -ov -o "$image"
{
    printf "data 'icns' (-16455) {\n"
    xxd -p -c 32 icon/PS4View.icns | sed 's/.*/$"&"/'
    printf '};\n'
} > "$stage/dmg-icon.r"
xcrun Rez "$stage/dmg-icon.r" -append -o "$image"
xcrun SetFile -a C "$image"
hdiutil verify "$image"
shasum -a 256 "$image"
printf 'Packaged %s (ad-hoc signed; not notarized)\n' "$image"
