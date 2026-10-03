#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${PACKAGE_VERSION:-1.0.0}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential cmake ninja-build python3 qtbase5-dev qtmultimedia5-dev libqt5svg5-dev libqt5multimedia5-plugins gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad libgl1-mesa-dri xz-utils binutils
[ "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.31' ] || { echo 'Build in Debian 11 to preserve the glibc 2.31 baseline.' >&2; exit 1; }
deb_arch="$(dpkg --print-architecture)"
case "$deb_arch" in amd64) arch=x86_64 ;; arm64) arch=arm64 ;; i386) arch=i386 ;; armhf) arch=armhf ;; *) echo "Unsupported architecture: $deb_arch" >&2; exit 1 ;; esac
build="$PWD/build/compatibility-linux-$arch"
output="$PWD/dist/compatibility/linux-$arch"
portable="$build/Console-View"
package="$build/deb"
mkdir -p "$output" "$portable/bin" "$portable/lib" "$portable/plugins" "$package/DEBIAN"
for plugin in camerabin wrappercamerabinsrc v4l2src; do gst-inspect-1.0 "$plugin" > "$output/gstreamer-$plugin.txt"; done
cmake -S compatibility -B "$build/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build/cmake" --parallel 2
ctest --test-dir "$build/cmake" --output-on-failure | tee "$output/ctest.txt"
DESTDIR="$package" cmake --install "$build/cmake"
install -Dm644 packaging/compatibility/consoleview.desktop "$package/usr/share/applications/consoleview.desktop"
install -Dm644 icon/icon_1024.png "$package/usr/share/icons/hicolor/1024x1024/apps/consoleview.png"
documents="$package/usr/share/doc/console-view-compatibility"
mkdir -p "$documents"
cp -R packaging/compatibility/licenses "$documents/"
cp LICENSE "$documents/LICENSE.txt"
cp packaging/compatibility/THIRD-PARTY-NOTICES.txt packaging/compatibility/QT-SOURCE-OFFER.txt packaging/compatibility/REPLACING-QT.txt "$documents/"
dpkg-query -W -f='${Package} ${Version}\n' libqt5core5a libqt5gui5 libqt5widgets5 libqt5multimedia5 libqt5multimediawidgets5 libqt5svg5 libqt5multimedia5-plugins > "$documents/qt-package-versions.txt"
cat > "$package/DEBIAN/control" <<CONTROL
Package: console-view-compatibility
Version: $version
Section: video
Priority: optional
Architecture: $deb_arch
Maintainer: El Qorchi Ismail
Depends: libc6 (>= 2.31), libstdc++6 (>= 10), libgcc-s1, libqt5core5a (>= 5.15.2), libqt5gui5 (>= 5.15.2), libqt5widgets5 (>= 5.15.2), libqt5multimedia5 (>= 5.15.2), libqt5multimediawidgets5 (>= 5.15.2), libqt5svg5 (>= 5.15.2), libqt5multimedia5-plugins (>= 5.15.2), gstreamer1.0-tools, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad
Description: Console View HDMI capture viewer
 Displays an external capture card with automatic connection and a focused interface.
CONTROL
deb_name="Console-View-$version-Linux-$arch.deb"
dpkg-deb --build --root-owner-group "$package" "$output/$deb_name"
dpkg -i "$output/$deb_name"
QT_QPA_PLATFORM=offscreen /usr/bin/consoleview --smoke-test > "$output/installed-smoke.txt" 2>&1
cp "$build/cmake/consoleview" "$portable/bin/"
plugin_root="$(qmake -query QT_INSTALL_PLUGINS)"
mkdir -p "$portable/plugins/platforms" "$portable/plugins/mediaservice"
for plugin in libqxcb.so libqoffscreen.so libqminimal.so; do cp "$plugin_root/platforms/$plugin" "$portable/plugins/platforms/"; done
cp "$plugin_root/mediaservice/libgstcamerabin.so" "$portable/plugins/mediaservice/"
for category in audio imageformats iconengines; do if [ -d "$plugin_root/$category" ]; then cp -R "$plugin_root/$category" "$portable/plugins/"; fi; done
python3 packaging/compatibility/bundle-linux-qt.py "$portable"
printf '[Paths]\nPrefix=..\nLibraries=lib\nPlugins=plugins\n' > "$portable/bin/qt.conf"
cp packaging/compatibility/linux-launcher.sh "$portable/consoleview"
cp packaging/compatibility/linux-dependencies.sh "$portable/check-dependencies"
cp packaging/compatibility/LINUX-INSTALL.txt packaging/compatibility/THIRD-PARTY-NOTICES.txt packaging/compatibility/QT-SOURCE-OFFER.txt packaging/compatibility/REPLACING-QT.txt "$portable/"
cp LICENSE "$portable/LICENSE.txt"
cp -R packaging/compatibility/licenses/. "$portable/licenses/"
cp "$documents/qt-package-versions.txt" "$portable/"
cp icon/icon_1024.png "$portable/consoleview.png"
printf 'glibc\n' > "$portable/libc.txt"
printf '%s\n' "$arch" > "$portable/architecture.txt"
chmod +x "$portable/consoleview" "$portable/check-dependencies"
"$portable/check-dependencies"
python3 packaging/compatibility/check-linux-baseline.py "$portable" --arch "$arch" | tee "$output/elf-baseline.txt"
archive_name="Console-View-$version-Linux-$arch-Portable.tar.xz"
tar -C "$build" -cJf "$output/$archive_name" Console-View
extracted="$(mktemp -d)"
trap 'rm -rf "$extracted"' EXIT
tar -xJf "$output/$archive_name" -C "$extracted"
env -u QT_PLUGIN_PATH -u QML2_IMPORT_PATH QT_QPA_PLATFORM=offscreen "$extracted/Console-View/consoleview" --smoke-test > "$output/portable-extracted-smoke.txt" 2>&1
(cd "$output" && sha256sum "$deb_name" "$archive_name" > SHA256SUMS.txt)
