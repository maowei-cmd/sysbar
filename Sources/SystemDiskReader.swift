import Darwin
import Foundation

final class SystemDiskReader {
    struct Reading {
        let temperature: Double?
        let source: String?
        let model: String?
        let location: String?
        let interconnect: String?
        let bsdName: String?
        let percentageUsed: Int?
        let unavailableReason: String?

        var note: String? {
            if let model, let location { return "\(model) · \(location)" }
            if let model { return model }
            if let location { return "系统盘 · \(location)" }
            return nil
        }

        var isInternal: Bool {
            location == "内置"
        }
    }

    private(set) var reading = Reading(
        temperature: nil,
        source: nil,
        model: nil,
        location: nil,
        interconnect: nil,
        bsdName: nil,
        percentageUsed: nil,
        unavailableReason: "正在识别系统盘…"
    )

    private var lastReadAt: Date?
    private var bootBSDName: String?

    func refresh(nandTemperatures: [Double] = [], force: Bool = false) {
        let now = Date()
        if !force, let lastReadAt, now.timeIntervalSince(lastReadAt) < 5 {
            return
        }
        lastReadAt = now

        let deviceName = bootBSDName ?? Self.bootDeviceName()
        bootBSDName = deviceName
        guard let deviceName else {
            reading = Reading(
                temperature: nil,
                source: nil,
                model: nil,
                location: nil,
                interconnect: nil,
                bsdName: nil,
                percentageUsed: nil,
                unavailableReason: "无法确定系统盘设备"
            )
            return
        }

        var result = SysBarNVMeSMARTResult()
        let status = deviceName.withCString { SysBarReadNVMeSMART($0, &result) }

        let model = Self.cString(from: result.model, capacity: 64)
        let locationRaw = Self.cString(from: result.location, capacity: 32)
        let interconnect = Self.cString(from: result.interconnect, capacity: 32)
        let error = Self.cString(from: result.error, capacity: 192)

        let location: String?
        switch locationRaw.lowercased() {
        case "internal": location = "内置"
        case "external": location = "外置"
        default: location = locationRaw.isEmpty ? nil : locationRaw
        }

        let modelText = model.isEmpty ? nil : model
        let interconnectText = interconnect.isEmpty ? nil : interconnect

        if status == 0 && result.available != 0 {
            reading = Reading(
                temperature: result.temperatureCelsius,
                source: "NVMe SMART",
                model: modelText,
                location: location,
                interconnect: interconnectText,
                bsdName: deviceName,
                percentageUsed: Int(result.percentageUsed),
                unavailableReason: nil
            )
        } else {
            let canUseNANDFallback = location == "内置"
            let nandTemperature = canUseNANDFallback ? nandTemperatures.max() : nil
            let reason = error.isEmpty ? "系统盘未提供温度" : error
            reading = Reading(
                temperature: nandTemperature,
                source: nandTemperature == nil ? nil : "NAND 传感器",
                model: modelText,
                location: location,
                interconnect: interconnectText,
                bsdName: deviceName,
                percentageUsed: nil,
                unavailableReason: nandTemperature == nil ? reason : nil
            )
        }
    }

    private static func bootDeviceName() -> String? {
        var information = statfs()
        guard statfs("/", &information) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: information.f_mntfromname)
        let device = withUnsafePointer(to: &information.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        let prefix = "/dev/"
        if device.hasPrefix(prefix) {
            return String(device.dropFirst(prefix.count))
        }
        return device.isEmpty ? nil : device
    }

    private static func cString<T>(from value: T, capacity: Int) -> String {
        var copy = value
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
