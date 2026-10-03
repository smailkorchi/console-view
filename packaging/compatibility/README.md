# Compatibility packaging

`.github/workflows/compatibility.yml` builds the Qt compatibility source only.
It uploads CI artifacts and never creates or updates a public release.

| Target | Build baseline | Outputs |
|---|---|---|
| Windows x86/x64 | Qt5.15.2 MSVC2019; VS2022 v142 toolset and app-local runtime | Portable ZIP and Inno Setup6.7.3 EXE |
| Intel macOS | Qt5.15.2 clang_64; deployment10.13 | HFS+ DMG with Applications shortcut |
| Linux x86_64/arm64/i386/armhf | Debian11 container; glibc2.31; distribution Qt5.15.2 | `.deb` and Qt-bundled portable `.tar.xz` |
| Alpine Linux x86_64/arm64/i386/armhf | Alpine3.22 container; musl1.2.5; distribution Qt5.15.10 | Native musl Qt-bundled portable `.tar.xz` |

Each job runs the app's `--smoke-test` before packaging and again from its deployed
or installed tree. That test renders Home and verifies embedded assets without
starting camera discovery, video capture, microphone access, or audio monitoring.
Windows checks every deployed PE architecture and required Qt/media/runtime files.
macOS checks every bundled Mach-O's Intel slice, minimum-OS metadata, and absolute
library paths. Linux checks bundled ELF symbol requirements and the presence of
GStreamer `camerabin`, `wrappercamerabinsrc`, and `v4l2src`.

These gates verify build/deployment/startup contracts. They do not establish
physical capture, latency, sound, reconnect behavior, Windows7 runtime support,
or macOS10.13 runtime support. The workflows must execute successfully before any
compatibility artifact is described as a built release. Installer and DMG signing
are separate from these checks; no signing identity is configured in this workflow.

Linux's portable archive bundles replaceable Qt, ICU, JPEG, double-conversion,
and PCRE ABI libraries. GStreamer and the host graphics/audio stack remain system
dependencies. The `.deb` declares required packages. `install-linux.sh` verifies
the release checksum, libc, userspace architecture, and archive contents before
installing into per-user XDG paths. It requests native packages with normal package
manager confirmation when dependencies are missing. Debian/Ubuntu, Arch, and Alpine
use their Qt runtime packages to obtain the graphics dependency closure. Fedora
and openSUSE use the package's exact host-library capability list plus their
GStreamer packages, so Qt5 does not need to be available in their repositories.
Portable builds use X11, including XWayland on Wayland desktops. The glibc build
requires glibc2.31 or newer; the separate musl build requires musl1.2.5 or newer.
The 32-bit x86 build requires SSE2, and armhf requires ARMv7 hard-float. These
baselines cover common Linux desktops, not every Linux distribution or CPU.
An AppImage is not generated because a complete capture-plugin/runtime bundle
has not been verified.

The workflow pins action revisions resolved from their GitHub release/tag metadata
and checksums the Inno Setup compiler download. The multiarchitecture Debian image
is pinned to its registry manifest digest. Tool versions and source references are
recorded directly in the workflow and notices. Linux's `bundled-libraries.json`
records exact package/source versions and immutable Debian or Alpine source URLs;
`host-library-dependencies.txt` records the libraries supplied by the system.
Qt remains dynamically linked;
notices, LGPL/GPL texts, source-offer instructions, and replacement information
travel with each package. Preserve corresponding source when distributing binaries.

To run manually, use the workflow dispatch after the source is committed. The
Windows script needs its architecture, Qt SDK path, and Inno compiler path. The
macOS script requires `QT_DIR`. The Linux script is intended for an isolated
Debian11 container as root; `build-alpine.sh` uses an isolated Alpine3.22 container.
Both install build dependencies inside the container. Linux checks run CTest,
validate the installed `.deb` where applicable, and extract the portable archive
into a fresh directory before the final startup smoke test.
