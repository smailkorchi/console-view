# Contributing

Console View accepts bug reports, hardware compatibility reports, and focused
pull requests. Keep changes small and preserve the automatic connection flow.

Build on macOS 14 or later with Apple Command Line Tools:

```sh
./scripts/test.sh
./build.sh arm64
open "build/arm64/Console View.app"
```

Use `x86_64` instead of `arm64` for Intel. `./build.sh universal` produces both
architectures. Follow the [README's packaging prerequisites](README.md#build-the-native-mac-app)
to package the two release DMGs.

For a capture issue, include macOS version, Mac processor, card model, video
and audio device names, console, observed capture resolution/frame rate, and
whether unplugging and reconnecting recovers playback. Do not include private
logs or personal identifiers unnecessarily.

Test changes with no hardware, permission denial, Return Home during reconnection,
and your real capture device. Report the devices you actually tested; do not
turn local checks into a claim of universal hardware compatibility.

Contributions are submitted under the Console View Free Use License 1.0.
Submit only code you have the right to contribute under those terms. The
software and modified versions may be shared for free; selling them is
prohibited. Optional installation/support services are treated separately
by the license.

Windows and Linux support are future work. Current builds and releases are
native macOS only.
