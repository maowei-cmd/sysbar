#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="系统监控"
EXECUTABLE="SysBar"
APP_BUNDLE="build/${APP_NAME}.app"
SDK_PATH=$(xcrun --show-sdk-path)

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

clang -O2 -c Sources/NVMeSMART.c \
    -o build/NVMeSMART.o \
    -target arm64-apple-macos14.0 \
    -I"$SDK_PATH/System/Library/Frameworks/IOKit.framework/Versions/A/Headers"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -import-objc-header Sources/NVMeSMART.h \
    Sources/main.swift \
    Sources/Samplers.swift \
    Sources/TemperatureReader.swift \
    Sources/SensorClassifier.swift \
    Sources/NetworkSampler.swift \
    Sources/Version.swift \
    Sources/Updater.swift \
    Sources/SystemDiskReader.swift \
    build/NVMeSMART.o \
    -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" \
    -framework AppKit \
    -framework IOKit \
    -framework CoreFoundation

codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
echo "Built $APP_BUNDLE"
