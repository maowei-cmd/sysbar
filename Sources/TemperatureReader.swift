import Foundation

struct TemperatureReading {
    let name: String
    let celsius: Double
    let kind: TemperatureSensorKind

    var isCPU: Bool { kind == .cpuPrimary }
    var isCPUFallback: Bool { kind == .cpuFallback }
    var isDisk: Bool { kind == .disk }
}

final class TemperatureReader {
    enum Scope: Equatable {
        case primary
        case all
    }

    private typealias CreateClientFn = @convention(c) (CFAllocator?, UInt32, CFDictionary?) -> CFTypeRef?
    private typealias CreateLegacyClientFn = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias CopyServicesFn = @convention(c) (CFTypeRef?) -> CFArray?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef?, CFString) -> CFTypeRef?
    private typealias CopyEventFn = @convention(c) (CFTypeRef?, Int64, Int64, Int64) -> CFTypeRef?
    private typealias GetFloatFn = @convention(c) (CFTypeRef?, Int64) -> Double

    private struct Sensor {
        let service: CFTypeRef
        let name: String
        let kind: TemperatureSensorKind
    }

    private static let eventTypeTemperature: Int64 = 15
    private static let eventFieldTemperature: Int64 = 15 << 16

    private var client: CFTypeRef? // retained so cached sensor services stay valid
    private var sensors: [Sensor] = []
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?

    private(set) var initializationIssue: String?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            copyEvent = nil
            getFloat = nil
            initializationIssue = "无法加载 IOKit"
            return
        }
        guard let copyServices = Self.symbol(handle, "IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = Self.symbol(handle, "IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self) else {
            copyEvent = nil
            getFloat = nil
            initializationIssue = "IOHID 接口不可用"
            return
        }
        copyEvent = Self.symbol(handle, "IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        getFloat = Self.symbol(handle, "IOHIDEventGetFloatValue", as: GetFloatFn.self)

        var createdClient: CFTypeRef?
        if let create = Self.symbol(handle, "IOHIDEventSystemClientCreateWithType", as: CreateClientFn.self) {
            createdClient = create(kCFAllocatorDefault, 1, nil)
        }
        if createdClient == nil,
           let createLegacy = Self.symbol(handle, "IOHIDEventSystemClientCreate", as: CreateLegacyClientFn.self) {
            createdClient = createLegacy(kCFAllocatorDefault)
        }
        guard let createdClient, let serviceList = copyServices(createdClient) as? [CFTypeRef] else {
            initializationIssue = "无法创建 IOHID 客户端"
            return
        }
        client = createdClient

        for service in serviceList {
            guard let page = copyProperty(service, "PrimaryUsagePage" as CFString) as? NSNumber,
                  let usage = copyProperty(service, "PrimaryUsage" as CFString) as? NSNumber,
                  page.intValue == 0xFF00, usage.intValue == 5 else { continue }
            let name = (copyProperty(service, "Product" as CFString) as? String) ?? "Sensor \(sensors.count + 1)"
            sensors.append(Sensor(
                service: service,
                name: name,
                kind: TemperatureSensorClassifier.kind(for: name)
            ))
        }
        if sensors.isEmpty {
            initializationIssue = "未发现温度传感器"
        }
    }

    var totalSensorCount: Int { sensors.count }
    var cpuPrimarySensorNames: [String] { sensors.filter { $0.kind == .cpuPrimary }.map(\.name) }
    var cpuFallbackSensorNames: [String] { sensors.filter { $0.kind == .cpuFallback }.map(\.name) }
    var diskSensorNames: [String] { sensors.filter { $0.kind == .disk }.map(\.name) }

    func read(scope: Scope = .all) -> [TemperatureReading] {
        guard let copyEvent, let getFloat else { return [] }
        var readings: [TemperatureReading] = []
        readings.reserveCapacity(scope == .primary ? 16 : sensors.count)
        for sensor in sensors {
            if scope == .primary &&
                sensor.kind != .cpuPrimary &&
                sensor.kind != .cpuFallback &&
                sensor.kind != .disk {
                continue
            }
            guard let event = copyEvent(sensor.service, Self.eventTypeTemperature, 0, 0) else { continue }
            let celsius = getFloat(event, Self.eventFieldTemperature)
            guard celsius.isFinite, celsius > 0, celsius < 150 else { continue }
            readings.append(TemperatureReading(
                name: sensor.name,
                celsius: celsius,
                kind: sensor.kind
            ))
        }
        return readings
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
