import Foundation

func expect(_ name: String, _ expected: TemperatureSensorKind) {
    let actual = TemperatureSensorClassifier.kind(for: name)
    guard actual == expected else {
        print("FAIL: \(name) -> \(actual), expected \(expected)")
        exit(1)
    }
}

expect("PMU tdie6", .cpuPrimary)
expect("PMU2 tdie5", .other)
expect("NAND CH0 temp", .disk)
expect("NVMe SSD Temp", .disk)
expect("SOC MTR Temp Sensor0", .cpuFallback)
expect("pACC MTR Temp Sensor0", .cpuFallback)
expect("CPU Efficiency Core 1", .cpuFallback)
expect("GPU MTR Temp Sensor0", .other)
expect("PMU tdev2", .other)
expect("Battery Temp", .other)

func expectVersion(_ raw: String, equals expected: String) {
    guard let actual = AppVersion(raw) else {
        print("FAIL: \(raw) could not be parsed")
        exit(1)
    }
    guard actual == AppVersion(expected) else {
        print("FAIL: \(raw) -> \(actual), expected \(expected)")
        exit(1)
    }
}

expectVersion("v1.4", equals: "1.4.0")
expectVersion("1.10.0", equals: "1.10")
expectVersion("2", equals: "2.0.0")

guard AppVersion("1.4.1")! > AppVersion("1.4")! else {
    print("FAIL: 1.4.1 should be newer than 1.4")
    exit(1)
}
guard AppVersion("1.10")! > AppVersion("1.9.9")! else {
    print("FAIL: 1.10 should be newer than 1.9.9")
    exit(1)
}
guard AppVersion("v2.0")! > AppVersion("1.99.99")! else {
    print("FAIL: v2.0 should be newer than 1.99.99")
    exit(1)
}
guard AppVersion("not-a-version") == nil else {
    print("FAIL: invalid version should not parse")
    exit(1)
}

print("SensorClassifierTests and VersionTests passed")
