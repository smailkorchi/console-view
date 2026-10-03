# Console View compatibility preview — verification

These downloads are a separate Qt edition for Linux, Windows and older Intel Macs.
The current native macOS release remains 1.0.1. Compatibility app version: 1.0.0.

## Build and package checks

| Packages | Evidence | Checks passed |
| --- | --- | --- |
| Linux — four CPU architectures, glibc and musl | [CI 37099946615](https://github.com/smailkorchi/console-view/actions/runs/37099946615), source `fce14be` | 3/3 CTests for each build; installed/extracted startup; ELF architecture and runtime requirements; GStreamer camera plugins; archive checksums |
| Windows x86 and x64 | [CI 37100259502](https://github.com/smailkorchi/console-view/actions/runs/37100259502), source `6a134ae` | 3/3 CTests for each build; 35/36 deployed PE files and import closure; portable/extracted/installed GUI startup; actual per-user installation and uninstall; archive checksums |
| Intel Mac | [CI 37100261326](https://github.com/smailkorchi/console-view/actions/runs/37100261326), source `6a134ae` | 3/3 CTests; 25 x86_64 Mach-O files with minimum deployment 10.13; dependency closure; strict ad-hoc signature; Cocoa/offscreen startup before and after deployment and from the mounted DMG; Finder layout |

All compatibility application source is identical between these tested commits.
Later commits add packaging notices, runtime tests, and documentation.
The tests cover capture-mode selection, reconnect policy, the bounded audio queue,
startup, picture-only full screen and Return Home. Startup tests do not open a
capture device or record audio.

## Distribution installation tests

The unchanged x86_64 glibc archive passed terminal installation and repeat
installation in fresh Ubuntu 24.04, Fedora 44, Arch Linux and openSUSE Leap 16
containers. Dependencies were installed using each distribution's actual package
manager. The checks verified library/plugin availability, the installed launcher,
XDG desktop/icon entries and startup. Before publication, only the two release
network requests were redirected to the exact checked CI archive/checksum files.

The installed app also passed native X11/XCB startup on Xvfb in all four
containers, using those same checked archives. The rendered 900 × 620 Home
images were inspected and matched their logged hashes. See
[CI 37101028842](https://github.com/smailkorchi/console-view/actions/runs/37101028842),
runtime-test source `ff2e87f`. This is virtual X11 rendering, not physical GPU,
Wayland or capture-device verification.

## Baselines and limits

- Linux glibc packages require glibc 2.31 or newer and a compatible C++ runtime.
- Musl packages are built for Alpine 3.22 / musl 1.2.5 or newer.
- Linux CPU variants: x86_64, ARM64, i386 with SSE2, and ARMv7 hard-float.
- Linux desktop rendering uses X11 or XWayland. Native Wayland is not certified.
- Windows packages target Windows 10+; no native Windows ARM64 package is provided.
- Windows N editions require Microsoft's Media Feature Pack.
- The Intel Mac package targets macOS 10.13+ and was tested on an Intel macOS 15 CI runner.
- Mac apps are ad-hoc signed and not Apple notarized; Windows downloads are unsigned.

Actual High Sierra execution, physical capture-card video/audio, hot unplug/replug,
and multiple-card switching on these platforms remain unverified. Device drivers,
USB bandwidth, the console's HDMI signal and content protection affect capture.
Build/startup success does not certify every distribution or capture card.

## Library sources and notices

The release's corresponding-source archive contains verified upstream QtBase,
QtMultimedia and QtSvg 5.15.2 sources for Windows and Mac, plus the exact Debian or
Alpine source/build/patch files for libraries shipped in the Linux archives.
All 52 retained Linux files and the three upstream Qt archives were hash-verified.
Library versions were reconciled against every final package inventory.

Qt remains dynamically linked and replaceable. Library licenses and source/
replacement instructions are included in the packages. Windows and Mac packages
include upstream Qt third-party notices, including ANGLE. Windows checkout uses
CRLF line endings; normalizing them to LF reproduces the original notice text
exactly. Microsoft runtime binaries retain their own redistribution terms.

Sources have not been rebuilt for binary-equivalence verification. See the
source archive's provenance reports for exact library versions and upstream URLs.
