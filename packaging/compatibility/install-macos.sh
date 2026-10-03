#!/bin/sh
# Uses the system tools present on Intel macOS High Sierra; does not alter Gatekeeper.
set -eu

version=1.0.0
destination="$HOME/Applications"
usage() {
    printf 'Usage: sh install-macos.sh [--version 1.0.0] [--destination /absolute/Applications]\n'
    printf 'Downloads the compatibility DMG, verifies SHA-256 and its bundle signature, and copies the app.\n'
    printf 'Existing Console View.app installations are never replaced. The app is not launched.\n'
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --version|--destination)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --version) version=$2 ;;
                --destination) destination=$2 ;;
            esac
            shift 2 ;;
        *) usage >&2; fail "Unknown option: $1" ;;
    esac
done
printf '%s\n' "$version" | /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ { ok=1 } END { exit !(ok && NR == 1) }' || fail 'Use a numeric version, for example 1.0.0.'
case "$destination" in /*) ;; *) fail 'The destination must be an absolute directory path.' ;; esac
[ "$(uname -s)" = Darwin ] || fail 'This installer requires macOS.'
[ "$(uname -m)" = x86_64 ] || fail 'Use the native Console View package on Apple Silicon.'
os_version=$(/usr/bin/sw_vers -productVersion)
printf '%s\n' "$os_version" | /usr/bin/awk -F. '{ exit !(($1 == 10 && $2 >= 13) || $1 >= 11) }' || fail 'Intel macOS 10.13 or later is required.'
target="$destination/Console View.app"
[ ! -e "$target" ] && [ ! -L "$target" ] || fail "An app already exists at $target. Move it aside yourself before installing this edition."

asset="Console-View-$version-macOS-Intel-10.13.dmg"
release="https://github.com/smailkorchi/console-view/releases/download/v$version-compatibility"
work=$(mktemp -d "${TMPDIR:-/tmp}/console-view-install.XXXXXX")
mount_dir="$work/mounted"
mounted=false
copied=false
finished=false
cleanup() {
    if [ "$copied" = true ] && [ "$finished" = false ]; then
        rm -rf "$target"
    fi
    if [ "$mounted" = true ]; then
        hdiutil detach "$mount_dir" >/dev/null 2>&1 || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
printf 'Downloading Console View %s for Intel macOS 10.13+...\n' "$version"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 300 \
    "$release/SHA256SUMS-macOS-Intel-10.13.txt" -o "$work/SHA256SUMS.txt"
expected=$(/usr/bin/awk -v name="$asset" '
    $2 == name {
        count++; digest=tolower($1)
        if (length(digest) != 64 || digest !~ /^[0-9a-f]+$/) invalid=1
    }
    END { if (count != 1 || invalid) exit 1; print digest }
' "$work/SHA256SUMS.txt") || fail 'The release checksum file does not contain exactly one valid hash for this DMG.'
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 300 \
    "$release/$asset" -o "$work/$asset"
actual=$(/usr/bin/shasum -a 256 "$work/$asset" | /usr/bin/awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail 'DMG checksum mismatch. Nothing was installed.'
hdiutil verify "$work/$asset"
mkdir "$mount_dir"
hdiutil attach "$work/$asset" -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" >/dev/null
mounted=true
app="$mount_dir/Console View.app"
[ -d "$app" ] || fail 'The DMG contains no Console View.app.'
/usr/bin/codesign --verify --deep --strict "$app"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[ "$identifier" = local.ismail.consoleview.compatibility ] || fail 'The DMG does not contain the compatibility edition.'
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || fail 'The app version does not match the requested release.'
mkdir -p "$destination"
# An atomic directory reservation also rejects another installer creating this
# path after the initial check. Roll back only the directory this run created.
mkdir "$target" || fail "The destination is occupied or not writable: $target"
copied=true
/usr/bin/ditto "$app" "$target"
/usr/bin/codesign --verify --deep --strict "$target"
hdiutil detach "$mount_dir" >/dev/null
mounted=false
finished=true
printf 'Installed %s\n' "$target"
printf 'The app is ad-hoc signed, not Developer ID signed or notarized. SHA-256 checks integrity, not Apple trust.\n'
printf 'Open it from Finder. If macOS blocks it, review the app using the normal macOS security controls.\n'
