#!/usr/bin/env sh
set -eu
version=1.0.0
release_base='https://github.com/smailkorchi/console-view/releases/download/v1.0.0-compatibility'
no_dependencies=false
assume_yes=false
prefix=''
usage() { printf '%s\n' 'Usage: sh install-linux.sh [--prefix DIRECTORY] [--no-dependencies] [--yes]'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; prefix=$2; shift 2 ;;
    --no-dependencies) no_dependencies=true; shift ;;
    --yes) assume_yes=true; shift ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[ "$(uname -s)" = Linux ] || { echo 'This installer is for Linux.' >&2; exit 1; }
for command in curl sha256sum tar od awk mktemp; do command -v "$command" >/dev/null 2>&1 || { echo "Required command is missing: $command" >&2; exit 1; }; done
bits="$(getconf LONG_BIT 2>/dev/null || true)"
if [ -z "$bits" ]; then
  class="$(od -An -tu1 -j4 -N1 /bin/sh | tr -d ' ')"
  case "$class" in 1) bits=32 ;; 2) bits=64 ;; *) echo 'Cannot determine Linux userspace architecture.' >&2; exit 1 ;; esac
fi
case "$(uname -m):$bits" in
  x86_64:64) arch=x86_64 ;; x86_64:32|i386:32|i486:32|i586:32|i686:32) arch=i386 ;;
  aarch64:64|arm64:64) arch=arm64 ;; aarch64:32|arm64:32|armv7*:32|armv8*:32) arch=armhf ;;
  *) echo 'Supported Linux userspaces: x86_64, ARM64, i386/SSE2, ARMv7 hard-float.' >&2; exit 1 ;;
esac
libc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
if [ -n "$libc_version" ]; then
  libc=glibc
  printf '%s\n' "$libc_version" | awk '{split($2,v,"."); exit !(v[1]>2 || (v[1]==2 && v[2]>=31))}' || { echo 'This glibc build requires glibc 2.31 or newer.' >&2; exit 1; }
  archive="Console-View-$version-Linux-$arch-Portable.tar.xz"
else
  ldd_info="$(ldd --version 2>&1 || true)"
  printf '%s' "$ldd_info" | grep -qi musl || { echo 'Unknown libc. Use a glibc 2.31+ desktop or Alpine 3.22+.' >&2; exit 1; }
  libc=musl
  printf '%s\n' "$ldd_info" | awk '/Version/ {split($2,v,"."); good=(v[1]>1 || (v[1]==1 && (v[2]>2 || (v[2]==2 && v[3]>=5))))} END {exit !good}' || { echo 'This musl build requires musl 1.2.5 or newer (Alpine 3.22+).' >&2; exit 1; }
  archive="Console-View-$version-Linux-Musl-$arch-Portable.tar.xz"
fi
if [ -n "$prefix" ]; then
  case "$prefix" in /*) ;; *) echo '--prefix must be an absolute path.' >&2; exit 1 ;; esac
  data_home="$prefix/share"; bin_home="$prefix/bin"
else
  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"; bin_home="$HOME/.local/bin"
fi
case "$data_home:$bin_home" in *'
'*) echo 'Install paths cannot contain newlines.' >&2; exit 1 ;; esac
case "$data_home" in /*) ;; *) echo 'XDG_DATA_HOME must be an absolute path.' >&2; exit 1 ;; esac
scratch="$(mktemp -d)"
stage=''
trap 'rm -rf "$scratch"; if [ -n "$stage" ] && [ -d "$stage" ]; then rm -rf "$stage"; fi' EXIT HUP INT TERM
curl --fail --show-error --location --proto '=https' --tlsv1.2 "$release_base/SHA256SUMS.txt" -o "$scratch/SHA256SUMS.txt"
curl --fail --show-error --location --proto '=https' --tlsv1.2 "$release_base/$archive" -o "$scratch/$archive"
expected="$(awk -v name="$archive" '$2==name || $2=="*"name {print $1}' "$scratch/SHA256SUMS.txt")"
case "$expected" in ''|*[!0123456789abcdef]*) echo 'Missing or invalid release checksum.' >&2; exit 1 ;; esac
[ "${#expected}" -eq 64 ] || { echo 'Ambiguous release checksum.' >&2; exit 1; }
actual="$(sha256sum "$scratch/$archive" | awk '{print $1}')"
[ "$actual" = "$expected" ] || { echo 'Download checksum mismatch. Nothing was installed.' >&2; exit 1; }
tar -tJf "$scratch/$archive" | awk '$0!="Console-View" && $0!="Console-View/" && $0!~/^Console-View\// {bad=1} /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || { echo 'Invalid archive paths. Nothing was installed.' >&2; exit 1; }
if tar -tvJf "$scratch/$archive" | grep -Eq '^[lh]'; then echo 'Unexpected links in archive. Nothing was installed.' >&2; exit 1; fi
tar -xJf "$scratch/$archive" --no-same-owner -C "$scratch"
application="$scratch/Console-View"
for file in consoleview check-dependencies bin/consoleview plugins/platforms/libqxcb.so plugins/mediaservice/libgstcamerabin.so lib/libQt5Widgets.so.5 LICENSE.txt consoleview.png libc.txt architecture.txt bundled-libraries.json host-library-dependencies.txt; do
  [ -f "$application/$file" ] || { echo "Incomplete release: $file" >&2; exit 1; }
done
[ "$(cat "$application/libc.txt")" = "$libc" ] && [ "$(cat "$application/architecture.txt")" = "$arch" ] || { echo 'Package architecture/libc mismatch.' >&2; exit 1; }
case "$arch" in x86_64) elf_class=2; elf_machine=62 ;; arm64) elf_class=2; elf_machine=183 ;; i386) elf_class=1; elf_machine=3 ;; armhf) elf_class=1; elf_machine=40 ;; esac
[ "$(od -An -tu1 -j4 -N1 "$application/bin/consoleview" | tr -d ' ')" = "$elf_class" ] && [ "$(od -An -tu2 -j18 -N2 "$application/bin/consoleview" | tr -d ' ')" = "$elf_machine" ] || { echo 'Executable architecture mismatch.' >&2; exit 1; }
run_package_manager() {
  if [ "$(id -u)" = 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo "$@"; elif command -v doas >/dev/null 2>&1; then doas "$@"; else echo 'Install the reported system dependencies with your package manager, then retry.' >&2; exit 1; fi
}
install_dependencies() {
  [ -f /etc/os-release ] && . /etc/os-release
  rpm_dependencies=false
  case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*)
      set -- apt-get install libqt5multimedia5-plugins libqt5svg5 libxcb-cursor0 gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
      $assume_yes && set -- "$@" -y ;;
    *fedora*|*rhel*|*centos*)
      set -- dnf install
      $assume_yes && set -- "$@" -y
      set -- "$@" gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free
      rpm_dependencies=true ;;
    *suse*)
      set -- zypper install gstreamer-utils gstreamer-plugins-base gstreamer-plugins-good gstreamer-plugins-bad
      rpm_dependencies=true
      if $assume_yes; then shift; set -- zypper --non-interactive "$@"; fi ;;
    *arch*)
      set -- pacman -S --needed qt5-multimedia qt5-svg xcb-util-cursor libsm libice gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad
      $assume_yes && set -- "$@" --noconfirm ;;
    *alpine*)
      set -- apk add qt5-qtmultimedia qt5-qtsvg xcb-util-cursor gstreamer-tools gst-plugins-base gst-plugins-good gst-plugins-bad
      if ! $assume_yes; then set -- "$@" --interactive; fi ;;
    *) echo 'This distribution needs manual installation of the libraries/plugins reported above.' >&2; exit 1 ;;
  esac
  if $rpm_dependencies; then
    while IFS= read -r library; do
      printf '%s\n' "$library" | grep -Eq '^lib[[:alnum:]_.+-]+\.so(\.[[:digit:]]+)*$' || { echo 'Invalid host-library manifest.' >&2; exit 1; }
      if [ "$bits" = 64 ]; then set -- "$@" "$library()(64bit)"; else set -- "$@" "$library"; fi
    done < "$application/host-library-dependencies.txt"
  fi
  echo 'Console View needs distribution graphics/audio/GStreamer packages. Your package manager will request confirmation.'
  run_package_manager "$@"
}
if ! "$application/check-dependencies"; then
  $no_dependencies && { echo 'Dependencies are missing; --no-dependencies leaves the system unchanged.' >&2; exit 1; }
  install_dependencies
  "$application/check-dependencies"
fi
QT_QPA_PLATFORM=offscreen "$application/consoleview" --smoke-test
install_root="$data_home/console-view"
launcher="$bin_home/consoleview"
if [ -e "$launcher" ] && ! grep -q '^# Console View per-user launcher$' "$launcher"; then echo "$launcher already exists and is not a Console View installer launcher. Nothing was replaced." >&2; exit 1; fi
if [ -e "$install_root/current" ] && [ ! -L "$install_root/current" ]; then echo 'Console View current path is not an installer symlink. Nothing was replaced.' >&2; exit 1; fi
release="$install_root/releases/$version-$libc-$arch-$expected"
mkdir -p "$install_root/releases" "$bin_home" "$data_home/applications" "$data_home/icons/hicolor/1024x1024/apps"
if [ ! -d "$release" ]; then
  stage="$(mktemp -d "$install_root/.stage.XXXXXX")"
  cp -R "$application/." "$stage/"
  mv "$stage" "$release"
fi
ln -sfn "releases/$version-$libc-$arch-$expected" "$install_root/current"
escape_shell() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'; }
printf '%s\n' '#!/bin/sh' '# Console View per-user launcher' "exec \"$(escape_shell "$install_root/current/consoleview")\" \"\$@\"" > "$launcher"
chmod +x "$launcher"
cp "$application/consoleview.png" "$data_home/icons/hicolor/1024x1024/apps/consoleview.png"
escape_desktop() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g'; }
cat > "$data_home/applications/consoleview.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Console View
Comment=View your console through an HDMI capture card
Exec="$(escape_desktop "$launcher")"
Icon=$data_home/icons/hicolor/1024x1024/apps/consoleview.png
Terminal=false
Categories=AudioVideo;Video;
DESKTOP
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$data_home/applications" || true; fi
printf 'Installed Console View %s (%s, %s).\nOpen Console View from your applications menu, or run %s\n' "$version" "$arch" "$libc" "$launcher"
case ":${PATH:-}:" in *":$bin_home:"*) ;; *) printf 'Add %s to PATH to use the consoleview command.\n' "$bin_home" ;; esac
