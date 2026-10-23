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

print("SensorClassifierTests passed")
