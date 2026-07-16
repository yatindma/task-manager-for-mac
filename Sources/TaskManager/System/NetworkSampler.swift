import Foundation
import IOKit
import IOKit.network
import SystemConfiguration

/// Per-interface throughput from `getifaddrs`, plus the addressing and Wi-Fi
/// details the Performance tab shows alongside the graph.
final class NetworkSampler {

    private struct Counters {
        var inBytes: UInt64
        var outBytes: UInt64
        var timestamp: Date
    }

    /// Raw `getifaddrs` facts for one interface, merged across its AF_* entries.
    private struct Interface {
        var bsdName: String
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var hasLinkData = false
        var isLoopback = false
        var ipv4 = ""
        var ipv6 = ""
        var mac = ""
    }

    private var previous: [String: Counters] = [:]
    private var histories: [String: (send: RingBuffer, receive: RingBuffer)] = [:]

    /// SCNetworkInterface enumeration and system_profiler are both far too slow
    /// to run at the UI's refresh rate, so they are cached and refreshed rarely.
    private var displayNames: [String: (name: String, isWiFi: Bool)] = [:]
    private var displayNamesRefreshed = Date.distantPast
    private var wifiInfo: [String: (ssid: String, rateMbps: Double)] = [:]
    private var wifiRefreshed = Date.distantPast
    private var ethernetLinkSpeeds: [String: Double] = [:]

    private let displayNameTTL: TimeInterval = 30
    private let wifiTTL: TimeInterval = 10

    func sample() -> [NetworkStats] {
        refreshDisplayNamesIfNeeded()
        refreshWiFiIfNeeded()

        let interfaces = readInterfaces()
        let now = Date()
        var result: [NetworkStats] = []
        var seen: Set<String> = []

        for interface in interfaces.values {
            guard !interface.isLoopback, interface.hasLinkData else { continue }

            let current = Counters(inBytes: interface.inBytes, outBytes: interface.outBytes, timestamp: now)
            var sendRate = 0.0
            var receiveRate = 0.0
            if let last = previous[interface.bsdName] {
                let elapsed = current.timestamp.timeIntervalSince(last.timestamp)
                if elapsed > 0 {
                    sendRate = Double(current.outBytes &- last.outBytes) / elapsed
                    receiveRate = Double(current.inBytes &- last.inBytes) / elapsed
                }
            }
            previous[interface.bsdName] = current

            // Windows lists configured adapters, so a routable address is the test —
            // it shows your Wi-Fi adapter at 0 B/s, and never shows a tunnel that is
            // merely present. Lifetime byte counters deliberately do NOT qualify an
            // interface: awdl0 (AirDrop) and idle utun tunnels all carry historical
            // traffic and would otherwise appear as adapters forever. An active VPN
            // has a routable address and still shows.
            let hasRoutableV6 = !interface.ipv6.isEmpty && !interface.ipv6.hasPrefix("fe80")
            guard !interface.ipv4.isEmpty || hasRoutableV6 else { continue }

            seen.insert(interface.bsdName)
            var history = histories[interface.bsdName] ?? (RingBuffer(), RingBuffer())
            history.send.push(sendRate)
            history.receive.push(receiveRate)
            histories[interface.bsdName] = history

            let identity = displayNames[interface.bsdName]
            let wifi = wifiInfo[interface.bsdName]
            let isWiFi = identity?.isWiFi ?? false

            result.append(
                NetworkStats(
                    interface: interface.bsdName,
                    displayName: identity?.name ?? interface.bsdName,
                    sendRate: sendRate,
                    receiveRate: receiveRate,
                    ipv4: interface.ipv4,
                    ipv6: interface.ipv6,
                    macAddress: interface.mac,
                    linkSpeedMbps: isWiFi ? (wifi?.rateMbps ?? 0) : (ethernetLinkSpeeds[interface.bsdName] ?? 0),
                    ssid: isWiFi ? (wifi?.ssid ?? "") : "",
                    isWiFi: isWiFi,
                    sendHistory: history.send,
                    receiveHistory: history.receive
                )
            )
        }

        previous = previous.filter { interfaces[$0.key] != nil }
        histories = histories.filter { seen.contains($0.key) }

        return result.sorted { $0.interface < $1.interface }
    }

    // MARK: - getifaddrs

    private func readInterfaces() -> [String: Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var interfaces: [String: Interface] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            var interface = interfaces[name] ?? Interface(bsdName: name)
            interface.isLoopback = (entry.ifa_flags & UInt32(IFF_LOOPBACK)) != 0

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    interface.inBytes = UInt64(data.pointee.ifi_ibytes)
                    interface.outBytes = UInt64(data.pointee.ifi_obytes)
                    interface.hasLinkData = true
                }
                interface.mac = macAddress(from: addr)
            case AF_INET:
                if interface.ipv4.isEmpty { interface.ipv4 = presentation(of: addr) }
            case AF_INET6:
                // Windows shows the routable address, so a global address wins
                // over a link-local one no matter which order they arrive in.
                let text = presentation(of: addr)
                let preferable = interface.ipv6.isEmpty
                    || (interface.ipv6.hasPrefix("fe80") && !text.hasPrefix("fe80"))
                if !text.isEmpty && preferable { interface.ipv6 = text }
            default:
                break
            }
            interfaces[name] = interface
        }
        return interfaces
    }

    private func presentation(of addr: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(addr.pointee.sa_len)
        guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return ""
        }
        // Scoped IPv6 addresses come back as "fe80::1%en0"; drop the zone.
        return String(cString: host).components(separatedBy: "%").first ?? ""
    }

    /// `sockaddr_dl` packs the interface name and the hardware address into one
    /// trailing buffer, so the MAC starts `sdl_nlen` bytes into `sdl_data`.
    private func macAddress(from addr: UnsafeMutablePointer<sockaddr>) -> String {
        let raw = UnsafeRawPointer(addr)
        let link = raw.assumingMemoryBound(to: sockaddr_dl.self)
        let addressLength = Int(link.pointee.sdl_alen)
        guard addressLength == 6 else { return "" }

        guard let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return "" }
        let start = dataOffset + Int(link.pointee.sdl_nlen)
        guard start + addressLength <= Int(link.pointee.sdl_len) else { return "" }

        let text = (0..<addressLength)
            .map { String(format: "%02x", raw.load(fromByteOffset: start + $0, as: UInt8.self)) }
            .joined(separator: ":")

        // Modern macOS redacts hardware addresses for unentitled processes,
        // handing back this fixed placeholder. Report nothing rather than a
        // fake address, so the UI can show an em-dash.
        return text == "02:00:00:00:00:00" ? "" : text
    }

    // MARK: - Names

    private func refreshDisplayNamesIfNeeded() {
        guard Date().timeIntervalSince(displayNamesRefreshed) > displayNameTTL else { return }
        displayNamesRefreshed = Date()

        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        var names: [String: (name: String, isWiFi: Bool)] = [:]
        var speeds: [String: Double] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let label = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsd
            let isWiFi = (SCNetworkInterfaceGetInterfaceType(interface) as String?)
                == (kSCNetworkInterfaceTypeIEEE80211 as String)
            names[bsd] = (label, isWiFi)
            if !isWiFi, let mbps = ethernetLinkSpeedMbps(bsdName: bsd) {
                speeds[bsd] = mbps
            }
        }
        displayNames = names
        ethernetLinkSpeeds = speeds
    }

    /// Reads the negotiated link speed for a wired interface from its
    /// IONetworkInterface's `IOLinkSpeed` property (bits/sec), walking up to the
    /// parent controller if the interface node itself doesn't carry it.
    private func ethernetLinkSpeedMbps(bsdName: String) -> Double? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var current = service
        var owns = false
        while current != 0 {
            if let property = IORegistryEntryCreateCFProperty(current, "IOLinkSpeed" as CFString, kCFAllocatorDefault, 0),
               let bitsPerSecond = (property.takeRetainedValue() as? NSNumber)?.doubleValue,
               bitsPerSecond > 0 {
                if owns { IOObjectRelease(current) }
                return bitsPerSecond / 1_000_000
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if owns { IOObjectRelease(current) }
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
            owns = true
        }
        return nil
    }

    // MARK: - Wi-Fi

    /// The `airport` command-line tool was removed from macOS, and CoreWLAN's
    /// SSID accessors need a location-services entitlement we do not have.
    /// `system_profiler` reports both without any privilege.
    private func refreshWiFiIfNeeded() {
        guard Date().timeIntervalSince(wifiRefreshed) > wifiTTL else { return }
        wifiRefreshed = Date()

        guard let data = runSystemProfiler(dataType: "SPAirPortDataType"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPAirPortDataType"] as? [[String: Any]]
        else {
            wifiInfo = [:]
            return
        }

        var info: [String: (ssid: String, rateMbps: Double)] = [:]
        for section in sections {
            guard let interfaces = section["spairport_airport_interfaces"] as? [[String: Any]] else { continue }
            for interface in interfaces {
                guard let bsd = interface["_name"] as? String,
                      let network = interface["spairport_current_network_information"] as? [String: Any],
                      let ssid = network["_name"] as? String
                else { continue }
                let rate = (network["spairport_network_rate"] as? NSNumber)?.doubleValue ?? 0
                info[bsd] = (ssid, rate)
            }
        }
        wifiInfo = info
    }

    private func runSystemProfiler(dataType: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", dataType]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
