#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -O Sources/SensorClassifier.swift Sources/Version.swift Tests/main.swift -o build/SensorClassifierTests
./build/SensorClassifierTests
