# Console View compatibility app

Separate Qt 5.15 / C++17 implementation for Windows x86/x64, Linux and older Intel macOS. It does not modify or replace the native Swift application. Hardware behavior is unverified until tested on the target operating system with a capture card.

## Build

Install a platform-matching Qt 5.15 toolchain with Widgets, Multimedia, MultimediaWidgets and Svg, plus CMake 3.16 or newer.

```sh
cmake -S compatibility -B build/compatibility -DCMAKE_PREFIX_PATH=/path/to/Qt/5.15/toolchain
cmake --build build/compatibility --config Release
```

CMake target and executable: `consoleview` (`consoleview.exe` on Windows). The macOS output is `consoleview.app`; minimum requested deployment target is 10.13. Build it with an Intel-compatible Qt/toolchain and an SDK that still supports that target. Linux requires Qt multimedia plugins and GStreamer camera components, including camerabin from Bad Plug-ins.

`consoleview --smoke-test` creates and renders the Home widget, validates embedded icon resources, then exits 0 on success or 2 on failure. It disables camera discovery/capture and audio startup. CI may use `QT_QPA_PLATFORM=offscreen`. This is startup evidence, not hardware verification.

## Capture behavior

The app automatically restores a selected device or chooses one positively identified external device. Several external devices require selection. Devices with unknown transport remain selectable but are never chosen automatically. Known built-in cameras are excluded. Windows uses SetupAPI removability metadata; Linux uses USB sysfs removability and stable V4L identifiers; macOS maps Qt IDs to AVFoundation transport metadata. These APIs classify transport, not the console brand or HDMI signal.

Return Home stops video/audio and cancels retries. Choosing a source resumes capture, including choosing the same card. While viewing, disconnection or a camera error recreates the camera automatically with 1/2/4/8-second retry delays. Device discovery polls once per second because Qt 5 has no portable hotplug signal.

The direct `QCameraViewfinder` exposes the capture driver's video. `QCamera::ActiveStatus` means the driver is running; it does not prove an HDMI signal, console connectivity, measured frame rate or the first real video frame. Black frames are not classified as signal loss.

Audio starts only after an explicit input selection. Qt 5 provides no reliable cross-platform association between a camera and its audio input, so the default microphone is never chosen. Missing or ambiguous saved audio names leave audio off. Playback uses a PCM format accepted by both input and output and a bounded 100 ms buffer. No generic 96 kHz mono or MS2109 reinterpretation is applied.

## Assets

The original app artwork is embedded unchanged; the Windows ICO contains scaled variants for platform icon sizes. GitHub Invertocat comes from [GitHub's official logo assets](https://brand.github.com/foundations/logo). Instagram's exact glyph comes from [Simple Icons](https://github.com/simple-icons/simple-icons), under CC0. These icons link to the author's profiles and do not imply endorsement.
