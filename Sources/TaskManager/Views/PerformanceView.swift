import IOKit
import AppKit
import SwiftUI

/// The Performance tab: resource list on the left, the big live graph plus the
/// stats grid on the right. Windows 11 layout, SF Pro typography.
struct PerformanceView: View {
    init() {}

    @ObservedObject private var monitor = SystemMonitor.shared

    @Environment(\.colorScheme) private var scheme

    @State private var selection: PerfSelection = .cpu
    @State private var cpuGraphMode: CPUGraphMode = .overall
    @State private var summaryView = false

    var body: some View {
        HStack(spacing: 0) {
            if !monitor.hasLoaded {
                loadingState
            } else {
                if !summaryView {
                    sidebar
                    Divider()
                }
                detail
            }
        }
        .background(WinTheme.Palette.card(scheme))
        .onChange(of: monitor.disks.count) { _, _ in normalizeSelection() }
        .onChange(of: monitor.networks.count) { _, _ in normalizeSelection() }
        .onChange(of: monitor.gpus.count) { _, _ in normalizeSelection() }
        // Recorded unconditionally so per-core history survives switching away from
        // CPU / Logical processors and back, instead of living inside that view.
        .onAppear { CoreHistoryStore.shared.record(monitor.cpu.perCore) }
        .onChange(of: monitor.cpu.perCore) { _, new in CoreHistoryStore.shared.record(new) }
    }

    /// The graphs need a first sample before they can draw anything; an empty
    /// axis frame reads as a broken app rather than a loading one.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reading performance counters…")
                .font(WinTheme.Typography.row)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                PerfSidebarItem(
                    title: PerfResource.cpu.rawValue,
                    detail: cpuSidebarDetail,
                    values: monitor.cpu.history.values,
                    color: WinTheme.Graph.cpu(scheme),
                    isSelected: selection == .cpu
                ) { selection = .cpu }

                PerfSidebarItem(
                    title: PerfResource.memory.rawValue,
                    detail: memorySidebarDetail,
                    values: monitor.memory.history.values,
                    color: WinTheme.Graph.memory(scheme),
                    isSelected: selection == .memory
                ) { selection = .memory }

                ForEach(Array(monitor.disks.enumerated()), id: \.element.id) { index, disk in
                    PerfSidebarItem(
                        title: diskTitle(index: index, disk: disk),
                        detail: WinTheme.percent(disk.activePercent),
                        values: disk.history.values,
                        color: WinTheme.Graph.disk(scheme),
                        isSelected: selection == .disk(index)
                    ) { selection = .disk(index) }
                }

                ForEach(Array(monitor.networks.enumerated()), id: \.element.id) { index, net in
                    PerfSidebarItem(
                        title: net.displayName.isEmpty ? net.interface : net.displayName,
                        detail: networkSidebarDetail(net),
                        values: net.receiveHistory.values,
                        secondary: net.sendHistory.values,
                        upperBound: net.throughputPeak,
                        color: WinTheme.Graph.network(scheme),
                        isSelected: selection == .network(index)
                    ) { selection = .network(index) }
                }

                ForEach(Array(monitor.gpus.enumerated()), id: \.element.id) { index, gpu in
                    PerfSidebarItem(
                        title: "GPU \(index)",
                        detail: "\(gpu.name)  \(WinTheme.percent(gpu.utilization))",
                        values: gpu.history.values,
                        color: WinTheme.Graph.gpu(scheme),
                        isSelected: selection == .gpu(index)
                    ) { selection = .gpu(index) }
                }
            }
            .padding(WinTheme.Metrics.cellPadding)
        }
        .frame(width: WinTheme.Metrics.sidebarExpandedWidth + 60)
        .background(WinTheme.Palette.mica(scheme))
    }

    private var cpuSidebarDetail: String {
        let cpu = monitor.cpu
        guard cpu.speedGHz > 0 else { return WinTheme.percent(cpu.usage) }
        return "\(WinTheme.percent(cpu.usage))  \(Self.ghz(cpu.speedGHz))"
    }

    private var memorySidebarDetail: String {
        let memory = monitor.memory
        return "\(Self.gb(memory.usedBytes))/\(Self.gb(memory.totalBytes)) GB "
            + "(\(WinTheme.percent(memory.usedPercent)))"
    }

    private func networkSidebarDetail(_ net: NetworkStats) -> String {
        "S: \(Self.mbps(net.sendRate)) R: \(Self.mbps(net.receiveRate)) Mbps"
    }

    private func diskTitle(index: Int, disk: DiskStats) -> String {
        "Disk \(index) (\(disk.name))"
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !summaryView {
                HStack(alignment: .firstTextBaseline) {
                    Text(detailTitle)
                        .font(WinTheme.Typography.sectionTitle)
                        .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                    Spacer()
                    Text(detailHardware)
                        .font(WinTheme.Typography.statLabel)
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                }
            }

            graphSection

            if !summaryView {
                ScrollView {
                    statsSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var graphSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text(axisTitle)
                Spacer()
                Text(axisMaximum)
            }
            .font(WinTheme.Typography.statLabel)
            .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            Group {
                if case .cpu = selection, cpuGraphMode == .logicalProcessors {
                    MultiCoreGraph(color: WinTheme.Graph.cpu(scheme))
                } else {
                    PerfGraph(
                        values: primaryHistory,
                        secondary: secondaryHistory,
                        upperBound: graphUpperBound,
                        color: graphColor
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 230, maxHeight: summaryView ? .infinity : 230)
            .clipped()

            HStack {
                Text("60 seconds")
                Spacer()
                Text("0")
            }
            .font(WinTheme.Typography.statLabel)
            .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
        .contextMenu { graphMenu }
    }

    @ViewBuilder
    private var graphMenu: some View {
        // Windows exposes "Change graph to" only for CPU. "Show kernel times" needs
        // per-mode CPU accounting macOS does not publish, so it is omitted.
        if case .cpu = selection {
            Menu("Change graph to") {
                Button(check(cpuGraphMode == .overall) + "Overall utilization") {
                    cpuGraphMode = .overall
                }
                Button(check(cpuGraphMode == .logicalProcessors) + "Logical processors") {
                    cpuGraphMode = .logicalProcessors
                }
            }
        }
        Button("Graph summary view") { summaryView.toggle() }
        Divider()
        Button("Copy") { copySummary() }
    }

    /// SwiftUI context menus cannot render a checkmark next to a plain Button,
    /// so the active mode is marked inline.
    private func check(_ isOn: Bool) -> String { isOn ? "✓ " : "   " }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        switch selection {
        case .cpu: cpuStats
        case .memory: memoryStats
        case .disk(let index):
            if let disk = monitor.disks[safe: index] { diskStats(disk) }
        case .network(let index):
            if let net = monitor.networks[safe: index] { networkStats(net) }
        case .gpu(let index):
            if let gpu = monitor.gpus[safe: index] { gpuStats(gpu) }
        }
    }

    private var cpuStats: some View {
        let cpu = monitor.cpu
        return HStack(alignment: .top, spacing: 32) {
            LazyVGrid(columns: statColumns(4), alignment: .leading, spacing: 12) {
                StatBlock(label: "Utilization", value: WinTheme.percent(cpu.usage))
                StatBlock(label: "Speed", value: Self.ghz(cpu.speedGHz))
                StatBlock(label: "Processes", value: "\(cpu.processCount)")
                StatBlock(label: "Threads", value: "\(cpu.threadCount)")
                StatBlock(label: "Handles", value: "\(cpu.handleCount)")
                StatBlock(label: "Up time", value: WinTheme.uptime(cpu.uptime))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HardwareBlock(rows: [
                ("Base speed:", Self.ghz(cpu.maxSpeedGHz)),
                ("Sockets:", "\(CPUHardware.sockets)"),
                ("Cores:", "\(cpu.cores)"),
                ("Logical processors:", "\(cpu.logicalProcessors)"),
                ("Virtualization:", CPUHardware.virtualization),
                ("L1 cache:", CPUHardware.l1),
                ("L2 cache:", CPUHardware.l2),
                ("L3 cache:", CPUHardware.l3)
            ])
        }
    }

    private var memoryStats: some View {
        let memory = monitor.memory
        return VStack(alignment: .leading, spacing: 16) {
            MemoryCompositionBar(memory: memory)

            HStack(alignment: .top, spacing: 32) {
                LazyVGrid(columns: statColumns(4), alignment: .leading, spacing: 12) {
                    StatBlock(label: "In use", value: WinTheme.bytes(memory.usedBytes))
                    StatBlock(label: "Available", value: WinTheme.bytes(memory.availableBytes))
                    StatBlock(label: "Committed", value: committedText(memory))
                    StatBlock(label: "Cached", value: WinTheme.bytes(memory.cachedBytes))
                    // Windows' paged / non-paged kernel pools have no macOS analogue.
                    // Wired and compressed are the closest published figures.
                    StatBlock(label: "Wired (non-paged)", value: WinTheme.bytes(memory.wiredBytes))
                    StatBlock(label: "Compressed", value: WinTheme.bytes(memory.compressedBytes))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HardwareBlock(rows: [
                    ("Speed:", memory.speedMHz > 0 ? "\(memory.speedMHz) MHz" : Self.unavailable),
                    ("Slots used:", memory.slotsUsed.isEmpty ? Self.unavailable : memory.slotsUsed),
                    ("Form factor:", memory.formFactor.isEmpty ? Self.unavailable : memory.formFactor),
                    ("Swap in use:", WinTheme.bytes(memory.swapUsedBytes)),
                    ("Swap size:", WinTheme.bytes(memory.swapTotalBytes))
                ])
            }
        }
    }

    private func diskStats(_ disk: DiskStats) -> some View {
        HStack(alignment: .top, spacing: 32) {
            LazyVGrid(columns: statColumns(4), alignment: .leading, spacing: 12) {
                StatBlock(label: "Active time", value: WinTheme.percent(disk.activePercent))
                // Per-request latency is only in root-only IOKit drive statistics.
                StatBlock(label: "Average response time", value: Self.unavailable)
                StatBlock(label: "Read speed", value: WinTheme.rate(disk.readRate))
                StatBlock(label: "Write speed", value: WinTheme.rate(disk.writeRate))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HardwareBlock(rows: [
                ("Capacity:", WinTheme.bytes(disk.capacityBytes)),
                ("Formatted:", Self.formattedCapacity(of: disk)),
                ("System disk:", Self.isSystemDisk(disk) ? "Yes" : "No"),
                ("Page file:", Self.isSystemDisk(disk) ? "Yes (dynamic swap)" : "No"),
                ("Type:", disk.isSSD ? "SSD" : "HDD"),
                ("Model:", disk.model.isEmpty ? Self.unavailable : disk.model)
            ])
        }
    }

    private func networkStats(_ net: NetworkStats) -> some View {
        HStack(alignment: .top, spacing: 32) {
            LazyVGrid(columns: statColumns(2), alignment: .leading, spacing: 12) {
                StatBlock(label: "Send", value: WinTheme.rate(net.sendRate))
                StatBlock(label: "Receive", value: WinTheme.rate(net.receiveRate))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HardwareBlock(rows: [
                ("Adapter name:", net.displayName.isEmpty ? net.interface : net.displayName),
                ("SSID:", net.ssid.isEmpty ? Self.unavailable : net.ssid),
                ("Connection type:", net.isWiFi ? "802.11 Wi-Fi" : "Ethernet"),
                ("Link speed:", net.linkSpeedMbps > 0
                    ? String(format: "%.0f Mbps", net.linkSpeedMbps) : Self.unavailable),
                ("IPv4 address:", net.ipv4.isEmpty ? Self.unavailable : net.ipv4),
                ("IPv6 address:", net.ipv6.isEmpty ? Self.unavailable : net.ipv6)
            ])
        }
    }

    private func gpuStats(_ gpu: GPUStats) -> some View {
        HStack(alignment: .top, spacing: 32) {
            LazyVGrid(columns: statColumns(2), alignment: .leading, spacing: 12) {
                StatBlock(label: "Utilization", value: WinTheme.percent(gpu.utilization))
                StatBlock(label: "Shared GPU memory",
                          value: "\(WinTheme.bytes(gpu.vramUsedBytes))/\(WinTheme.bytes(gpu.vramTotalBytes))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HardwareBlock(rows: [
                // macOS publishes no GPU driver version or PCI slot for Apple GPUs.
                ("Driver version:", Self.unavailable),
                ("Location:", gpu.isIntegrated ? "Integrated" : Self.unavailable),
                ("Shared memory:", WinTheme.bytes(gpu.vramTotalBytes))
            ])
        }
    }

    private func committedText(_ memory: MemoryStats) -> String {
        let committed = memory.usedBytes + memory.swapUsedBytes
        let limit = memory.totalBytes + memory.swapTotalBytes
        return "\(WinTheme.bytes(committed))/\(WinTheme.bytes(limit))"
    }

    private func statColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: count)
    }

    // MARK: - Selection-derived values

    private var detailTitle: String {
        switch selection {
        case .cpu: return PerfResource.cpu.rawValue
        case .memory: return PerfResource.memory.rawValue
        case .disk(let i):
            guard let disk = monitor.disks[safe: i] else { return PerfResource.disk.rawValue }
            return diskTitle(index: i, disk: disk)
        case .network(let i):
            guard let net = monitor.networks[safe: i] else { return PerfResource.network.rawValue }
            return net.displayName.isEmpty ? net.interface : net.displayName
        case .gpu(let i): return "GPU \(i)"
        }
    }

    private var detailHardware: String {
        switch selection {
        case .cpu: return monitor.cpu.model
        case .memory:
            return "\(WinTheme.bytes(monitor.memory.totalBytes))"
        case .disk(let i): return monitor.disks[safe: i]?.model ?? ""
        case .network(let i):
            guard let net = monitor.networks[safe: i] else { return "" }
            return net.isWiFi ? "Wi-Fi (\(net.interface))" : "Ethernet (\(net.interface))"
        case .gpu(let i): return monitor.gpus[safe: i]?.name ?? ""
        }
    }

    private var axisTitle: String {
        switch selection {
        case .cpu: return "% Utilization"
        case .memory: return "Memory usage"
        case .disk: return "% Active time"
        case .network: return "Throughput"
        case .gpu: return "% Utilization"
        }
    }

    private var axisMaximum: String {
        switch selection {
        case .memory:
            return WinTheme.bytes(monitor.memory.totalBytes)
        case .network(let i):
            guard let net = monitor.networks[safe: i] else { return "0" }
            return WinTheme.rate(net.throughputPeak)
        default:
            return "100%"
        }
    }

    private var graphColor: Color {
        switch selection {
        case .cpu: return WinTheme.Graph.cpu(scheme)
        case .memory: return WinTheme.Graph.memory(scheme)
        case .disk: return WinTheme.Graph.disk(scheme)
        case .network: return WinTheme.Graph.network(scheme)
        case .gpu: return WinTheme.Graph.gpu(scheme)
        }
    }

    private var primaryHistory: [Double] {
        switch selection {
        case .cpu: return monitor.cpu.history.values
        case .memory: return monitor.memory.history.values
        case .disk(let i): return monitor.disks[safe: i]?.history.values ?? []
        case .network(let i): return monitor.networks[safe: i]?.receiveHistory.values ?? []
        case .gpu(let i): return monitor.gpus[safe: i]?.history.values ?? []
        }
    }

    private var secondaryHistory: [Double]? {
        guard case .network(let i) = selection else { return nil }
        return monitor.networks[safe: i]?.sendHistory.values
    }

    private var graphUpperBound: Double {
        guard case .network(let i) = selection,
              let net = monitor.networks[safe: i] else { return 100 }
        return net.throughputPeak
    }

    /// Keep the selection valid when an interface or disk disappears mid-session.
    private func normalizeSelection() {
        switch selection {
        case .disk(let i) where monitor.disks[safe: i] == nil: selection = .cpu
        case .network(let i) where monitor.networks[safe: i] == nil: selection = .cpu
        case .gpu(let i) where monitor.gpus[safe: i] == nil: selection = .cpu
        default: break
        }
    }

    // MARK: - Copy

    private func copySummary() {
        var lines = ["\(detailTitle)  \(detailHardware)"]
        switch selection {
        case .cpu:
            let cpu = monitor.cpu
            lines += [
                "Utilization: \(WinTheme.percent(cpu.usage))",
                "Speed: \(Self.ghz(cpu.speedGHz))",
                "Processes: \(cpu.processCount)",
                "Threads: \(cpu.threadCount)",
                "Handles: \(cpu.handleCount)",
                "Up time: \(WinTheme.uptime(cpu.uptime))",
                "Base speed: \(Self.ghz(cpu.maxSpeedGHz))",
                "Cores: \(cpu.cores)",
                "Logical processors: \(cpu.logicalProcessors)"
            ]
        case .memory:
            let memory = monitor.memory
            lines += [
                "In use: \(WinTheme.bytes(memory.usedBytes))",
                "Available: \(WinTheme.bytes(memory.availableBytes))",
                "Committed: \(committedText(memory))",
                "Cached: \(WinTheme.bytes(memory.cachedBytes))"
            ]
        case .disk(let i):
            guard let disk = monitor.disks[safe: i] else { break }
            lines += [
                "Active time: \(WinTheme.percent(disk.activePercent))",
                "Read speed: \(WinTheme.rate(disk.readRate))",
                "Write speed: \(WinTheme.rate(disk.writeRate))",
                "Capacity: \(WinTheme.bytes(disk.capacityBytes))"
            ]
        case .network(let i):
            guard let net = monitor.networks[safe: i] else { break }
            lines += [
                "Send: \(WinTheme.rate(net.sendRate))",
                "Receive: \(WinTheme.rate(net.receiveRate))",
                "IPv4 address: \(net.ipv4)",
                "IPv6 address: \(net.ipv6)"
            ]
        case .gpu(let i):
            guard let gpu = monitor.gpus[safe: i] else { break }
            lines += [
                "Utilization: \(WinTheme.percent(gpu.utilization))",
                "Shared memory: \(WinTheme.bytes(gpu.vramTotalBytes))"
            ]
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Formatting helpers

    static let unavailable = "—"

    static func ghz(_ value: Double) -> String {
        value > 0 ? String(format: "%.2f GHz", value) : unavailable
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    static func mbps(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond * 8 / 1_000_000
        return value < 0.05 ? "0" : String(format: "%.1f", value)
    }

    /// DiskStats.name is the BSD name of the physical disk ("disk0"), while the root
    /// mount reports an APFS synthesized device ("disk3s3s1"). Neither a volume-name
    /// comparison nor a "/dev/<name>" prefix test bridges that, so we resolve the
    /// mount back to its physical media through the IORegistry.
    static func isSystemDisk(_ disk: DiskStats) -> Bool {
        physicalDisk(ofMount: "/") == disk.name
    }

    static func formattedCapacity(of disk: DiskStats) -> String {
        guard let volume = volumeURL(backedBy: disk),
              let total = try? volume
                  .resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity
        else { return unavailable }
        return WinTheme.bytes(Double(total))
    }

    /// The mounted volume sitting on this physical disk. "/Volumes/<bsdName>" never
    /// exists, so each mount is resolved to its physical media and matched.
    private static func volumeURL(backedBy disk: DiskStats) -> URL? {
        if isSystemDisk(disk) { return URL(fileURLWithPath: "/") }
        let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        return mounts.first { physicalDisk(ofMount: $0.path) == disk.name }
    }

    /// Mount point -> physical whole-disk BSD name. Cached: the mount topology does
    /// not change while a Performance row is on screen, and this walks the registry.
    private static let physicalDiskCache = NSCache<NSString, NSString>()

    private static func physicalDisk(ofMount path: String) -> String? {
        if let hit = physicalDiskCache.object(forKey: path as NSString) { return hit as String }

        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let device = withUnsafePointer(to: fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { return nil }

        guard let whole = wholePhysicalMedia(bsd: String(device.dropFirst("/dev/".count)))
        else { return nil }
        physicalDiskCache.setObject(whole as NSString, forKey: path as NSString)
        return whole
    }

    /// Breadth-first over IORegistry parents. An APFS volume's first parent chain ends
    /// at the synthesized container media ("disk3", Whole=true), so a depth-first walk
    /// stops one layer short of the real device — the physical store hangs off a
    /// sibling branch. We take the first whole media that is not APFS-synthesized.
    private static func wholePhysicalMedia(bsd: String) -> String? {
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd)
        let start = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard start != 0 else { return nil }

        var queue = [start]
        var seen = Set<UInt64>()

        while !queue.isEmpty {
            var next: [io_service_t] = []
            for node in queue {
                defer { IOObjectRelease(node) }

                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(node, &entryID)
                guard seen.insert(entryID).inserted else { continue }

                var raw = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(node, &raw)
                let isSynthesized = String(cString: raw).contains("APFS")

                let whole = IORegistryEntryCreateCFProperty(node, "Whole" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool ?? false
                let name = IORegistryEntryCreateCFProperty(node, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String

                if whole, !isSynthesized, let name {
                    next.forEach { IOObjectRelease($0) }
                    return name
                }

                var iterator: io_iterator_t = 0
                if IORegistryEntryGetParentIterator(node, kIOServicePlane, &iterator) == KERN_SUCCESS {
                    while case let parent = IOIteratorNext(iterator), parent != 0 {
                        next.append(parent)
                    }
                    IOObjectRelease(iterator)
                }
            }
            queue = next
        }
        return nil
    }
}

// MARK: - Supporting types

private enum PerfSelection: Hashable {
    case cpu
    case memory
    case disk(Int)
    case network(Int)
    case gpu(Int)
}

private enum CPUGraphMode {
    case overall
    case logicalProcessors
}

/// A big number over its caption, the way Windows lays out the Performance stats.
private struct StatBlock: View {
    var label: String
    var value: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(WinTheme.Typography.statValue)
                .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(WinTheme.Typography.statLabel)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
    }
}

/// The right-hand "label: value" hardware column.
private struct HardwareBlock: View {
    var rows: [(String, String)]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
                        .gridColumnAlignment(.leading)
                    Text(row.1)
                        .foregroundStyle(WinTheme.Palette.textPrimary(scheme))
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(WinTheme.Typography.statLabel)
    }
}

/// Windows' memory-composition bar. macOS has no Modified/Standby split, so the
/// bands are In use / Cached / Free — the figures the kernel actually publishes.
private struct MemoryCompositionBar: View {
    var memory: MemoryStats

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory composition")
                .font(WinTheme.Typography.statLabel)
                .foregroundStyle(WinTheme.Palette.textSecondary(scheme))

            GeometryReader { geometry in
                let total = Double(max(memory.totalBytes, 1))
                let used = Double(memory.usedBytes)
                let cached = Double(memory.cachedBytes)
                let free = max(total - used - cached, 0)
                let color = WinTheme.Graph.memory(scheme)

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(color.opacity(0.75))
                        .frame(width: geometry.size.width * used / total)
                    Rectangle()
                        .fill(color.opacity(WinTheme.Graph.fillOpacity))
                        .frame(width: geometry.size.width * cached / total)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: geometry.size.width * free / total)
                }
                .overlay(
                    Rectangle()
                        .strokeBorder(WinTheme.Palette.border(scheme), lineWidth: 1)
                )
            }
            .frame(height: 34)

            HStack(spacing: 16) {
                Text("In use  \(WinTheme.bytes(memory.usedBytes))")
                Text("Cached  \(WinTheme.bytes(memory.cachedBytes))")
                Text("Available  \(WinTheme.bytes(memory.availableBytes))")
            }
            .font(WinTheme.Typography.statLabel)
            .foregroundStyle(WinTheme.Palette.textSecondary(scheme))
        }
    }
}

/// Static CPU facts Windows shows in the hardware block, read once from sysctl.
private enum CPUHardware {
    static let sockets: Int = sysctlInt("hw.packages").map(Int.init) ?? 1

    static let virtualization: String =
        (sysctlInt("kern.hv_support") ?? 0) == 1 ? "Enabled" : "Not available"

    static let l1: String = cacheSize("hw.l1dcachesize")
    static let l2: String = cacheSize("hw.l2cachesize")
    static let l3: String = cacheSize("hw.l3cachesize")

    private static func cacheSize(_ name: String) -> String {
        guard let value = sysctlInt(name), value > 0 else { return PerformanceView.unavailable }
        return WinTheme.bytes(UInt64(value))
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        var value: Int64 = 0
        var length = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &length, nil, 0) == 0 else { return nil }
        return value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
