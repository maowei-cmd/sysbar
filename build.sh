#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="系统监控"
EXECUTABLE="SysBar"
APP_BUNDLE="build/${APP_NAME}.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    Sources/main.swift \
    Sources/Samplers.swift \
    Sources/TemperatureReader.swift \
    Sources/SensorClassifier.swift \
    Sources/NetworkSampler.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" \
    -framework AppKit

codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
echo "Built $APP_BUNDLE"
