import Foundation

struct NetworkInterfaceStats {
    let name: String
    let ipAddress: String?
    let downloadPerSecond: Double
    let uploadPerSecond: Double
    let receivedTotal: UInt64
    let sentTotal: UInt64
}

struct NetworkSample {
    var downloadPerSecond: Double = 0
    var uploadPerSecond: Double = 0
    var receivedTotal: UInt64 = 0
    var sentTotal: UInt64 = 0
    var interfaces: [NetworkInterfaceStats] = []
}

final class NetworkSampler {
    private struct Counters {
        var received: UInt64
        var sent: UInt64
    }

    private var previousCounters: [String: Counters] = [:]
    private var previousTimestamp: TimeInterval?

    func sample() -> NetworkSample {
        let now = ProcessInfo.processInfo.systemUptime
        let counters = Self.readCounters()
        let addresses = Self.readIPv4Addresses()
        let elapsed = previousTimestamp.map { max(0, now - $0) } ?? 0

        var interfaces: [NetworkInterfaceStats] = []
        var download: Double = 0
        var upload: Double = 0
        var totalReceived: UInt64 = 0
        var totalSent: UInt64 = 0

        for (name, current) in counters {
            let previous = previousCounters[name]
            var receivedRate: Double = 0
            var sentRate: Double = 0
            if let previous, elapsed > 0 {
                receivedRate = Self.delta(current.received, previous.received) / elapsed
                sentRate = Self.delta(current.sent, previous.sent) / elapsed
            }

            download += receivedRate
            upload += sentRate
            totalReceived += current.received
            totalSent += current.sent

            let address = addresses[name]
            if address != nil || current.received > 0 || current.sent > 0 {
                interfaces.append(NetworkInterfaceStats(
                    name: name,
                    ipAddress: address,
                    downloadPerSecond: receivedRate,
                    uploadPerSecond: sentRate,
                    receivedTotal: current.received,
                    sentTotal: current.sent
                ))
            }
        }

        interfaces.sort { lhs, rhs in
            if (lhs.ipAddress != nil) != (rhs.ipAddress != nil) {
                return lhs.ipAddress != nil
            }
            let lhsTotal = lhs.receivedTotal + lhs.sentTotal
            let rhsTotal = rhs.receivedTotal + rhs.sentTotal
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            return lhs.name < rhs.name
        }

        previousCounters = counters
        previousTimestamp = now

        return NetworkSample(
            downloadPerSecond: download,
            uploadPerSecond: upload,
            receivedTotal: totalReceived,
            sentTotal: totalSent,
            interfaces: interfaces
        )
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
    }

    private static func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 8)
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &length, nil, 0) == 0 else { return [:] }

        var counters: [String: Counters] = [:]
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0 else { break }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let header2 = buffer.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if_indextoname(UInt32(header2.ifm_index), &nameBuffer)
                let name = String(cString: nameBuffer)
                if name.hasPrefix("en") {
                    counters[name] = Counters(
                        received: header2.ifm_data.ifi_ibytes,
                        sent: header2.ifm_data.ifi_obytes
                    )
                }
            }
            offset += messageLength
        }
        return counters
    }

    private static func readIPv4Addresses() -> [String: String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(first) }

        var addresses: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en"),
               let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
            }
            pointer = interface.ifa_next
        }
        return addresses
    }
}
