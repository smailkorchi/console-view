#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:-1.0.0}"
: "${QT_DIR:?Set QT_DIR to the Qt 5.15.2 clang_64 installation}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == x86_64 ]] || { printf 'Run this build on an Intel macOS runner.\n' >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Use a numeric package version, for example 1.0.0.\n' >&2; exit 2; }
[[ "$("$QT_DIR/bin/qmake" -query QT_VERSION)" == 5.15.2 ]] || { printf 'Qt 5.15.2 is required for this baseline.\n' >&2; exit 1; }
dmg_python="${DMG_PYTHON:-python3}"
"$dmg_python" -c 'import sys, ds_store, mac_alias; assert sys.version_info >= (3, 10), "DMG layout needs Python 3.10 or newer"'
build="${RUNNER_TEMP:-$PWD/build}/console-view-legacy-macos"
output="$PWD/dist/compatibility/macos-intel"
mkdir -p "$output" "$build"
stage=$(mktemp -d "$build/dmg.XXXXXX")
mount_dir=""
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mount_dir" >/dev/null 2>&1 || return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
export MACOSX_DEPLOYMENT_TARGET=10.13
{
    xcrun clang --version
    xcrun --show-sdk-path
    xcrun --show-sdk-version
    "$QT_DIR/bin/qmake" -query QT_VERSION
    sw_vers
} > "$output/build-toolchain.txt"
cmake -S compatibility -B "$build/cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_DIR" \
    -DBUILD_TESTING=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    '-DCMAKE_CXX_FLAGS=-Werror=unguarded-availability -Werror=unguarded-availability-new' \
    '-DCMAKE_OBJCXX_FLAGS=-Werror=unguarded-availability -Werror=unguarded-availability-new' \
    '-DCMAKE_EXE_LINKER_FLAGS=-Wl,-fatal_warnings' 2>&1 | tee "$output/configure.txt"
cmake --build "$build/cmake" --parallel 2 2>&1 | tee "$output/build.txt"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$build/cmake/consoleview.app/Contents/Info.plist")" == "$version" ]] || { printf 'Package version differs from the CMake app version.\n' >&2; exit 1; }
(cd "$build/cmake" && QT_QPA_PLATFORM=offscreen ctest --output-on-failure) 2>&1 | tee "$output/ctest.txt"
smoke() {
    local bundle="$1" label="$2"
    printf '\n%s startup smoke (no camera discovery or capture)\n' "$label" >> "$output/startup-smoke.txt"
    env -u QT_PLUGIN_PATH -u QML2_IMPORT_PATH -u QT_QPA_PLATFORM_PLUGIN_PATH \
        -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
        -u DYLD_FALLBACK_FRAMEWORK_PATH QT_QPA_PLATFORM=offscreen \
        "$bundle/Contents/MacOS/consoleview" --smoke-test >> "$output/startup-smoke.txt" 2>&1
}
: > "$output/startup-smoke.txt"
smoke "$build/cmake/consoleview.app" 'Before deployment'
payload="$stage/payload"
mkdir "$payload"
app="$payload/Console View.app"
ditto "$build/cmake/consoleview.app" "$app"
# Qt 5.15.2 macdeployqt deliberately excludes offscreen; include it before its
# recursive dylib dependency deployment so the packaged startup check is real.
mkdir -p "$app/Contents/PlugIns/platforms"
cp "$QT_DIR/plugins/platforms/libqoffscreen.dylib" "$app/Contents/PlugIns/platforms/"
"$QT_DIR/bin/macdeployqt" "$app" -always-overwrite -verbose=2
for plugin in platforms/libqcocoa.dylib platforms/libqoffscreen.dylib mediaservice/libqavfcamera.dylib audio/libqtaudio_coreaudio.dylib imageformats/libqsvg.dylib; do
    [[ -f "$app/Contents/PlugIns/$plugin" ]] || { printf 'Required Qt plugin is missing: %s\n' "$plugin" >&2; exit 1; }
done
mkdir -p "$app/Contents/Resources/legal"
cp LICENSE "$app/Contents/Resources/legal/LICENSE.txt"
cp packaging/compatibility/THIRD-PARTY-NOTICES.txt packaging/compatibility/QT-SOURCE-OFFER.txt packaging/compatibility/REPLACING-QT.txt "$app/Contents/Resources/legal/"
cp -R packaging/compatibility/licenses "$app/Contents/Resources/legal/"
cp packaging/compatibility/MACOS-INSTALL.txt "$app/Contents/Resources/"
cp packaging/compatibility/install-macos.sh "$output/install-macos.sh"
cp packaging/compatibility/MACOS-INSTALL.txt "$output/MACOS-INSTALL.txt"
chmod +x "$output/install-macos.sh"
"$dmg_python" packaging/compatibility/check-macos-baseline.py "$app" \
    --imports-report "$output/sdk-imports.txt" | tee "$output/mach-o-baseline.txt"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
smoke "$app" 'Deployed bundle'
ln -s /Applications "$payload/Applications"
cp icon/PS4View.icns "$payload/.VolumeIcon.icns"
mkdir "$payload/.background"
cp packaging/macos/background.tiff "$payload/.background/background.tiff"
image="$output/Console-View-$version-macOS-Intel-10.13.dmg"
writable="$stage/installer.dmg"
hdiutil create -volname 'Console View' -srcfolder "$payload" -format UDRW -fs HFS+ -ov "$writable"
hdiutil attach -nobrowse -noautoopen -mountrandom /Volumes -plist "$writable" > "$stage/mount.plist"
mount_dir=$("$dmg_python" -c 'import plistlib, sys; data = plistlib.load(open(sys.argv[1], "rb")); print(next(item["mount-point"] for item in data["system-entities"] if "mount-point" in item))' "$stage/mount.plist")
mounted=true
xcrun SetFile -a C "$mount_dir"
"$dmg_python" scripts/dmg-layout.py "$mount_dir" | tee "$output/dmg-layout.txt"
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
hdiutil attach "$image" -nobrowse -noautoopen -readonly -mountrandom /Volumes -plist > "$stage/mount.plist"
mount_dir=$("$dmg_python" -c 'import plistlib, sys; data = plistlib.load(open(sys.argv[1], "rb")); print(next(item["mount-point"] for item in data["system-entities"] if "mount-point" in item))' "$stage/mount.plist")
mounted=true
"$dmg_python" scripts/dmg-layout.py "$mount_dir" --verify >> "$output/dmg-layout.txt"
codesign --verify --deep --strict "$mount_dir/Console View.app"
"$dmg_python" packaging/compatibility/check-macos-baseline.py "$mount_dir/Console View.app" >> "$output/mach-o-baseline.txt"
smoke "$mount_dir/Console View.app" 'Mounted final DMG'
hdiutil detach "$mount_dir"
mounted=false
(cd "$output" && shasum -a 256 "$(basename "$image")") > "$output/SHA256SUMS-macOS-Intel-10.13.txt"
cp "$output/SHA256SUMS-macOS-Intel-10.13.txt" "$output/SHA256SUMS.txt"
printf 'Packaged %s; deployment metadata and runner startup checked, macOS 10.13 runtime and capture unverified.\n' "$image"
