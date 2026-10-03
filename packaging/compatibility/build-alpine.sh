#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/../.."
version="${PACKAGE_VERSION:-1.0.0}"
case "$(cat /etc/alpine-release)" in 3.22.*) ;; *) echo 'Build in Alpine 3.22 to preserve the musl baseline.' >&2; exit 1 ;; esac
apk add --no-cache build-base cmake ninja python3 qt5-qtbase-dev qt5-qtmultimedia-dev qt5-qtsvg-dev gstreamer-tools gst-plugins-base gst-plugins-good gst-plugins-bad mesa-dri-gallium mesa-gl mesa-egl mesa-gles xz binutils
apk_arch="$(apk --print-arch)"
case "$apk_arch" in x86_64) arch=x86_64 ;; aarch64) arch=arm64 ;; x86) arch=i386 ;; armv7) arch=armhf ;; *) echo "Unsupported Alpine architecture: $apk_arch" >&2; exit 1 ;; esac
build="$PWD/build/compatibility-linux-musl-$arch"
output="$PWD/dist/compatibility/linux-musl-$arch"
portable="$build/Console-View"
mkdir -p "$output" "$portable/bin" "$portable/lib" "$portable/plugins/platforms" "$portable/plugins/mediaservice"
for plugin in camerabin wrappercamerabinsrc v4l2src; do gst-inspect-1.0 "$plugin" > "$output/gstreamer-$plugin.txt"; done
cmake -S compatibility -B "$build/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$build/cmake" --parallel 2
ctest --test-dir "$build/cmake" --output-on-failure > "$output/ctest.txt" 2>&1 || { cat "$output/ctest.txt"; exit 1; }
cat "$output/ctest.txt"
cp "$build/cmake/consoleview" "$portable/bin/"
plugin_root="$(qmake-qt5 -query QT_INSTALL_PLUGINS)"
for plugin in libqxcb.so libqoffscreen.so libqminimal.so; do cp "$plugin_root/platforms/$plugin" "$portable/plugins/platforms/"; done
cp "$plugin_root/mediaservice/libgstcamerabin.so" "$portable/plugins/mediaservice/"
for category in audio imageformats iconengines; do if [ -d "$plugin_root/$category" ]; then cp -R "$plugin_root/$category" "$portable/plugins/"; fi; done
python3 packaging/compatibility/bundle-linux-qt.py "$portable"
printf '[Paths]\nPrefix=..\nLibraries=lib\nPlugins=plugins\n' > "$portable/bin/qt.conf"
cp packaging/compatibility/linux-launcher.sh "$portable/consoleview"
cp packaging/compatibility/linux-dependencies.sh "$portable/check-dependencies"
cp packaging/compatibility/LINUX-INSTALL.txt packaging/compatibility/THIRD-PARTY-NOTICES.txt packaging/compatibility/QT-SOURCE-OFFER.txt packaging/compatibility/REPLACING-QT.txt "$portable/"
cat >> "$portable/QT-SOURCE-OFFER.txt" <<'SOURCE'

Alpine musl package supplement
This package uses Alpine 3.22 Qt libraries, not the Debian libraries described above.
bundled-libraries.json records the exact package version, source origin and immutable
Alpine aports commit for each library. Its source_url points to the matching APKBUILD
and patches. Complete corresponding source consists of those patches/build files and
the upstream source archives referenced by that APKBUILD, available from the recorded
Alpine distfiles archive. Use that exact commit/version when rebuilding replacement
libraries. The distributor retains these matching sources under the same source offer.
SOURCE
cp LICENSE "$portable/LICENSE.txt"
cp -R packaging/compatibility/licenses/. "$portable/licenses/"
apk info -v | grep -E '^qt5-(qtbase|qtmultimedia|qtsvg)-' > "$portable/qt-package-versions.txt"
cp icon/icon_1024.png "$portable/consoleview.png"
printf 'musl\n' > "$portable/libc.txt"
printf '%s\n' "$arch" > "$portable/architecture.txt"
chmod +x "$portable/consoleview" "$portable/check-dependencies"
"$portable/check-dependencies"
python3 packaging/compatibility/check-linux-baseline.py "$portable" --libc musl --arch "$arch" > "$output/elf-baseline.txt" 2>&1 || { cat "$output/elf-baseline.txt"; exit 1; }
cat "$output/elf-baseline.txt"
archive_name="Console-View-$version-Linux-Musl-$arch-Portable.tar.xz"
tar -C "$build" -cJf "$output/$archive_name" Console-View
extracted="$(mktemp -d)"
trap 'rm -rf "$extracted"' EXIT
tar -xJf "$output/$archive_name" -C "$extracted"
env -u QT_PLUGIN_PATH -u QML2_IMPORT_PATH QT_QPA_PLATFORM=offscreen "$extracted/Console-View/consoleview" --smoke-test > "$output/portable-extracted-smoke.txt" 2>&1
(cd "$output" && sha256sum "$archive_name" > SHA256SUMS.txt)
