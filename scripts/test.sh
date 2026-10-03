#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -swift-version 5 \
    -parse-as-library -framework AppKit -framework SwiftUI \
    -framework AVFoundation -framework CoreMedia -framework IOKit \
    -framework CoreAudio Sources/Models.swift Sources/CaptureController.swift \
    Sources/MS2109Audio.swift Tests/*.swift \
    -o build/tests/CapturePolicyTests
build/tests/CapturePolicyTests
