import Foundation

struct CPUSample {
    var total: Double = 0
    var cores: [Double] = []
}

final class CPUSampler {
    private var previousTicks: [UInt64] = []

    func sample() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return CPUSample() }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let coreCount = Int(cpuCount)
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
        var current = [UInt64](repeating: 0, count: coreCount * 4)
        for index in current.indices {
            current[index] = UInt64(ticks[index])
        }

        let previous = previousTicks
        previousTicks = current

        guard previous.count == current.count else {
            return CPUSample(total: 0, cores: Array(repeating: 0, count: coreCount))
        }

        var cores: [Double] = []
        cores.reserveCapacity(coreCount)
        var totalBusy: Double = 0
        var totalTicks: Double = 0

        for core in 0..<coreCount {
            let base = core * 4
            let user = Self.delta(current[base], previous[base])
            let system = Self.delta(current[base + 1], previous[base + 1])
            let idle = Self.delta(current[base + 2], previous[base + 2])
            let nice = Self.delta(current[base + 3], previous[base + 3])
            let busy = user + system + nice
            let all = busy + idle
            cores.append(all > 0 ? busy / all * 100 : 0)
            totalBusy += busy
            totalTicks += all
        }

        return CPUSample(total: totalTicks > 0 ? totalBusy / totalTicks * 100 : 0, cores: cores)
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
    }
}

struct MemorySample {
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var purgeable: UInt64 = 0
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory

    var percent: Double {
        guard total > 0 else { return 0 }
        return min(100, Double(used) / Double(total) * 100)
    }
}

final class MemorySampler {
    private let pageSize = UInt64(sysconf(_SC_PAGESIZE))

    func sample() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemorySample() }

        let total = ProcessInfo.processInfo.physicalMemory
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * Int64(pageSize)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let used = min(total, UInt64(app) + wired + compressed)

        return MemorySample(
            used: used,
            app: UInt64(app),
            wired: wired,
            compressed: compressed,
            free: free,
            purgeable: purgeable,
            total: total
        )
    }
}
