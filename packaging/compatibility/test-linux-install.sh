#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -s) != Linux || ! -f /.dockerenv && ! -f /run/.containerenv || $(id -u) != 0 ]]; then
  echo 'Run this dependency-installation test only as root inside a disposable Linux container.' >&2
  exit 1
fi
[[ $# == 1 && $(uname -m) == x86_64 ]] || { echo 'Usage: bash test-linux-install.sh X86_64_GLIBC_ARTIFACT_DIRECTORY' >&2; exit 1; }
artifact_dir=$(cd "$1" && pwd)
script_dir=$(cd "$(dirname "$0")" && pwd)
archive=Console-View-1.0.0-Linux-x86_64-Portable.tar.xz
[[ -f $artifact_dir/$archive && -f $artifact_dir/SHA256SUMS.txt ]]
. /etc/os-release
printf 'Testing Console View terminal installation on %s (%s).\n' "$PRETTY_NAME" "$(uname -m)"
case "$ID ${ID_LIKE:-}" in
  *debian*|*ubuntu*) apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates xz-utils tar coreutils findutils ;;
  *fedora*|*rhel*) dnf install -y curl ca-certificates xz tar coreutils findutils glibc-common ;;
  *arch*) pacman -Syu --noconfirm --needed curl ca-certificates xz tar coreutils findutils ;;
  *suse*) zypper --non-interactive refresh; zypper --non-interactive install curl ca-certificates xz tar coreutils findutils ;;
  *) echo "Unsupported container distribution: $ID" >&2; exit 1 ;;
esac
scratch=$(mktemp -d)
trap 'if [[ -n ${xvfb_pid:-} ]]; then kill "$xvfb_pid" 2>/dev/null || true; fi; rm -rf "$scratch"' EXIT
prefix="$scratch/Install With Spaces"
mkdir "$scratch/bin"
cat > "$scratch/bin/curl" <<'CURL'
#!/bin/sh
set -eu
file=''; output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    --proto) shift 2 ;;
    https://github.com/smailkorchi/console-view/releases/download/v1.0.0-compatibility/SHA256SUMS.txt) file=SHA256SUMS.txt; shift ;;
    https://github.com/smailkorchi/console-view/releases/download/v1.0.0-compatibility/Console-View-1.0.0-Linux-x86_64-Portable.tar.xz) file=Console-View-1.0.0-Linux-x86_64-Portable.tar.xz; shift ;;
    --fail|--show-error|--location|--tlsv1.2) shift ;;
    *) echo "Unexpected release download argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$file" ] && [ -n "$output" ]
printf 'Using unchanged build artifact: %s\n' "$file"
cp "$CONSOLE_VIEW_TEST_ARTIFACTS/$file" "$output"
CURL
chmod +x "$scratch/bin/curl"
export CONSOLE_VIEW_TEST_ARTIFACTS="$artifact_dir"
export PATH="$scratch/bin:$PATH"
for attempt in 1 2; do
  printf '\nInstallation attempt %s (real distribution dependencies).\n' "$attempt"
  sh "$script_dir/install-linux.sh" --prefix "$prefix" --yes
  [[ -x $prefix/bin/consoleview && -L $prefix/share/console-view/current ]]
  [[ -f $prefix/share/applications/consoleview.desktop && -f $prefix/share/icons/hicolor/1024x1024/apps/consoleview.png ]]
  grep -Fx "Exec=\"$prefix/bin/consoleview\"" "$prefix/share/applications/consoleview.desktop"
  "$prefix/share/console-view/current/check-dependencies"
  QT_QPA_PLATFORM=offscreen "$prefix/bin/consoleview" --smoke-test | tee "$scratch/startup.txt"
  grep -Fx 'Console View Qt startup smoke passed' "$scratch/startup.txt"
  current=$(readlink "$prefix/share/console-view/current")
  if [[ $attempt == 1 ]]; then first_release=$current; else [[ $current == "$first_release" ]]; fi
done
# Install display-test tools only after the fresh-system dependency checks pass.
printf '\nInstalling test-only Xvfb and fonts for the X11 startup check.\n'
case "$ID ${ID_LIKE:-}" in
  *debian*|*ubuntu*) DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb fonts-dejavu-core ;;
  *fedora*|*rhel*) dnf install -y xorg-x11-server-Xvfb dejavu-sans-fonts ;;
  *arch*) pacman -S --noconfirm --needed xorg-server-xvfb ttf-dejavu ;;
  *suse*) zypper --non-interactive install xorg-x11-server-Xvfb dejavu-fonts ;;
esac
Xvfb :93 -screen 0 1024x768x24 -nolisten tcp > "$scratch/xvfb.txt" 2>&1 &
xvfb_pid=$!
for attempt in {1..50}; do
  [[ -S /tmp/.X11-unix/X93 ]] && break
  kill -0 "$xvfb_pid" 2>/dev/null || { cat "$scratch/xvfb.txt"; exit 1; }
  sleep 0.1
done
[[ -S /tmp/.X11-unix/X93 ]] || { cat "$scratch/xvfb.txt"; exit 1; }
image=${CONSOLE_VIEW_SMOKE_IMAGE:-"$artifact_dir/home-xcb.png"}
mkdir -p "$(dirname "$image")"
timeout 30s env DISPLAY=:93 QT_QPA_PLATFORM=xcb CONSOLE_VIEW_SMOKE_IMAGE="$image" \
  "$prefix/bin/consoleview" --smoke-test | tee "$scratch/startup-xcb.txt"
grep -Fx 'Console View Qt startup smoke passed' "$scratch/startup-xcb.txt"
[[ -s $image && $(od -An -tx1 -N8 "$image" | tr -d ' \n') == 89504e470d0a1a0a ]]
printf 'XCB home image: '; sha256sum "$image"
printf '\nPASS: %s; %s; real library/GStreamer checks, installed launcher, desktop entry, repeat installation, and rendered X11 startup.\n' "$PRETTY_NAME" "$(getconf GNU_LIBC_VERSION)"
