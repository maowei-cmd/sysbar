import Foundation

enum TemperatureSensorKind: Equatable {
    case cpuPrimary
    case cpuFallback
    case disk
    case other
}

enum TemperatureSensorClassifier {
    private static let fallbackExclusions = [
        "GPU", "NAND", "SSD", "NVME", "BATTERY", "CHARGER", "AMBIENT", "PMU2"
    ]
    private static let fallbackPositives = [
        "CPU", "SOC", "PACC", "EACC", "CORE", "DIE"
    ]

    static func kind(for name: String) -> TemperatureSensorKind {
        let uppercase = name.uppercased()
        if uppercase.hasPrefix("PMU TDIE") { return .cpuPrimary }
        if ["NAND", "SSD", "NVME"].contains(where: { uppercase.contains($0) }) {
            return .disk
        }
        let excluded = fallbackExclusions.contains(where: { uppercase.contains($0) })
        let matchesCPU = fallbackPositives.contains(where: { uppercase.contains($0) })
        if !excluded && matchesCPU { return .cpuFallback }
        return .other
    }
}
