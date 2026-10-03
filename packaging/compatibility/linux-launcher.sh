#!/usr/bin/env sh
set -eu
application_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export LD_LIBRARY_PATH="$application_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$application_dir/plugins"
if [ -d "$application_dir/share/icu" ]; then export ICU_DATA="$application_dir/share/icu"; fi
# Ship one well-supported desktop platform: Wayland sessions use their XWayland server.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
unset QT_QPA_PLATFORM_PLUGIN_PATH
exec "$application_dir/bin/consoleview" "$@"
