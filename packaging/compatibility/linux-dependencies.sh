#!/usr/bin/env sh
set -eu
application_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$application_dir/bin/consoleview" ]; then
  dependency_log="$(mktemp)"
  trap 'rm -f "$dependency_log"' EXIT HUP INT TERM
  export LD_LIBRARY_PATH="$application_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  if ! find "$application_dir/bin" "$application_dir/plugins" -type f \( -name consoleview -o -name '*.so' \) -exec sh -c 'for file do ldd "$file" || exit 1; done' sh {} + > "$dependency_log" 2>&1 || grep -Eq 'not found|Error loading|Error relocating' "$dependency_log"; then
    cat "$dependency_log" >&2; exit 1
  fi
fi
if ! command -v gst-inspect-1.0 >/dev/null 2>&1 || ! gst-inspect-1.0 camerabin >/dev/null 2>&1 || ! gst-inspect-1.0 wrappercamerabinsrc >/dev/null 2>&1 || ! gst-inspect-1.0 v4l2src >/dev/null 2>&1; then
  echo 'Required GStreamer capture plugins are missing.' >&2
  echo 'Debian/Ubuntu: sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad' >&2
  echo 'Fedora: sudo dnf install gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-bad-free' >&2
  echo 'openSUSE: sudo zypper install gstreamer-utils gstreamer-plugins-base gstreamer-plugins-good gstreamer-plugins-bad' >&2
  echo 'Arch: sudo pacman -S gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad' >&2
  echo 'Alpine: sudo apk add gstreamer-tools gst-plugins-base gst-plugins-good gst-plugins-bad' >&2
  exit 1
fi
echo 'GStreamer capture plugins are present. This does not test a physical capture card.'
