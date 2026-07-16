import AppKit
import Foundation

// MARK: - Navigation

/// The sidebar pages, in Windows 11 Task Manager order.
enum Tab: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case performance = "Performance"
    case appHistory = "App history"
    case startupApps = "Startup apps"
    case users = "Users"
    case details = "Details"
    case services = "Services"

    var id: String { rawValue }

    /// SF Symbol standing in for the Fluent icon Windows uses.
    var symbol: String {
        switch self {
        case .processes: return "list.bullet.rectangle"
        case .performance: return "waveform.path.ecg"
        case .appHistory: return "clock.arrow.circlepath"
        case .startupApps: return "power"
        case .users: return "person.2"
        case .details: return "tablecells"
        case .services: return "gearshape.2"
        }
    }
}

// MARK: - Processes

enum ProcKind: Int, Comparable {
    case app = 0
    case background = 1
    case system = 2

    /// Windows' group header text, adapted for macOS.
    var groupTitle: String {
        switch self {
        case .app: return "Apps"
        case .background: return "Background processes"
        case .system: return "macOS processes"
        }
    }

    static func < (a: ProcKind, b: ProcKind) -> Bool { a.rawValue < b.rawValue }
}

enum ProcStatus: Equatable {
    case running
    case suspended
    case notResponding

    var label: String {
        switch self {
        case .running: return ""
        case .suspended: return "Suspended"
        case .notResponding: return "Not responding"
        }
    }
}

/// Windows' qualitative power columns.
enum PowerLevel: Int, Comparable {
    case veryLow = 0
    case low = 1
    case moderate = 2
    case high = 3
    case veryHigh = 4

    var label: String {
        switch self {
        case .veryLow: return "Very low"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }

    /// Derived from CPU share the way Windows approximates power draw.
    static func fromCPU(_ percent: Double) -> PowerLevel {
        switch percent {
        case ..<0.5: return .veryLow
        case ..<3: return .low
        case ..<12: return .moderate
        case ..<30: return .high
        default: return .veryHigh
        }
    }

    static func < (a: PowerLevel, b: PowerLevel) -> Bool { a.rawValue < b.rawValue }
}

/// One row in the Processes / Details tables.
///
/// `cpu`, `gpu` are percentages 0...100 normalised across all cores.
/// `diskRate`, `networkRate` are bytes per second.
struct ProcRow: Identifiable, Equatable {
    var id: pid_t { pid }

    var pid: pid_t
    var parentPID: pid_t
    var name: String
    /// Localised app name when known, otherwise the executable name.
    var displayName: String
    var kind: ProcKind
    var status: ProcStatus
    var user: String
    var path: String

    var cpu: Double
    var memoryBytes: UInt64
    var diskRate: Double
    var networkRate: Double
    var gpu: Double
    var threads: Int
    var handles: Int
    var startTime: Date

    /// App icon when the process owns one. Not part of equality — comparing
    /// NSImage on every 1 Hz refresh would be pure overhead.
    var icon: NSImage?

    /// Child rows shown under an expanded app, as Windows nests windows/tabs.
    var children: [ProcRow] = []

    var powerUsage: PowerLevel { .fromCPU(cpu) }
    var powerTrend: PowerLevel { .fromCPU(cpu) }

    /// Totals including children, which is what Windows shows on a collapsed app row.
    var totalCPU: Double { cpu + children.reduce(0) { $0 + $1.totalCPU } }
    var totalMemory: UInt64 { memoryBytes + children.reduce(0) { $0 + $1.totalMemory } }
    var totalDisk: Double { diskRate + children.reduce(0) { $0 + $1.totalDisk } }
    var totalNetwork: Double { networkRate + children.reduce(0) { $0 + $1.totalNetwork } }
    var totalGPU: Double { gpu + children.reduce(0) { $0 + $1.totalGPU } }

    static func == (a: ProcRow, b: ProcRow) -> Bool {
        a.pid == b.pid && a.cpu == b.cpu && a.memoryBytes == b.memoryBytes
            && a.diskRate == b.diskRate && a.networkRate == b.networkRate
            && a.gpu == b.gpu && a.status == b.status && a.threads == b.threads
            && a.children == b.children
    }
}

// MARK: - Sortable columns

enum ProcColumn: String, CaseIterable, Identifiable {
    case name = "Name"
    case status = "Status"
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case gpu = "GPU"
    case powerUsage = "Power usage"
    case powerTrend = "Power usage trend"

    var id: String { rawValue }

    var width: CGFloat? {
        switch self {
        case .name: return nil          // flexible
        case .status: return 84
        case .cpu: return 72
        case .memory: return 92
        case .disk: return 84
        case .network: return 92
        case .gpu: return 64
        case .powerUsage: return 96
        case .powerTrend: return 128
        }
    }

    /// Windows tints these columns by load; the rest stay flat.
    var isHeated: Bool {
        switch self {
        case .cpu, .memory, .disk, .network, .gpu: return true
        default: return false
        }
    }
}

// MARK: - Performance

/// Fixed-size history of samples, oldest first. The Performance graphs read this.
struct RingBuffer {
    private(set) var values: [Double]
    let capacity: Int

    init(capacity: Int = 60) {
        self.capacity = capacity
        self.values = Array(repeating: 0, count: capacity)
    }

    mutating func push(_ value: Double) {
        values.removeFirst()
        values.append(value)
    }

    var latest: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
}

/// The left-hand list on the Performance tab.
enum PerfResource: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case gpu = "GPU"

    var id: String { rawValue }
}

struct CPUStats {
    var usage: Double = 0                 // 0...100
    var perCore: [Double] = []
    var speedGHz: Double = 0
    var maxSpeedGHz: Double = 0
    var cores: Int = 0
    var logicalProcessors: Int = 0
    var processCount: Int = 0
    var threadCount: Int = 0
    var handleCount: Int = 0
    var uptime: TimeInterval = 0
    var model: String = ""
    var history = RingBuffer()
}

struct MemoryStats {
    var usedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var speedMHz: Int = 0
    var slotsUsed: String = ""
    var formFactor: String = ""
    var history = RingBuffer()

    var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct DiskStats: Identifiable {
    var id: String { name }
    var name: String = ""
    var model: String = ""
    var activePercent: Double = 0
    var readRate: Double = 0
    var writeRate: Double = 0
    var capacityBytes: UInt64 = 0
    var isSSD: Bool = true
    var history = RingBuffer()
    var readHistory = RingBuffer()
    var writeHistory = RingBuffer()
}

struct NetworkStats: Identifiable {
    var id: String { interface }
    var interface: String = ""
    var displayName: String = ""
    var sendRate: Double = 0
    var receiveRate: Double = 0
    var ipv4: String = ""
    var ipv6: String = ""
    var macAddress: String = ""
    var linkSpeedMbps: Double = 0
    var ssid: String = ""
    var isWiFi: Bool = false
    var sendHistory = RingBuffer()
    var receiveHistory = RingBuffer()

    /// Windows scales the network graph to the highest rate seen in the window.
    var throughputPeak: Double {
        max(sendHistory.peak, receiveHistory.peak, 1024)
    }
}

struct GPUStats: Identifiable {
    var id: String { name }
    var name: String = ""
    var utilization: Double = 0
    var vramUsedBytes: UInt64 = 0
    var vramTotalBytes: UInt64 = 0
    var isIntegrated: Bool = true
    var history = RingBuffer()
}

// MARK: - Other tabs

struct ServiceRow: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var pid: pid_t?
    var displayName: String
    var status: String        // "Running" / "Stopped"
    var lastExitCode: Int
    var isSystem: Bool
    var plistPath: String
}

struct StartupRow: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var publisher: String
    var status: String        // "Enabled" / "Disabled"
    var impact: String        // "High" / "Medium" / "Low" / "Not measured"
    var path: String
    var isLoginItem: Bool
}

struct UserRow: Identifiable, Equatable {
    var id: String { username }
    var username: String
    var fullName: String
    var status: String        // "Active" / "Disconnected"
    var sessionKind: String   // "Console" / "SSH" / "Terminal"
    var loginTime: Date
    var cpu: Double
    var memoryBytes: UInt64
    var processes: [ProcRow] = []
}

struct AppHistoryRow: Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var cpuTimeSeconds: Double
    var networkBytes: UInt64
    var meteredNetworkBytes: UInt64
    var icon: NSImage?

    static func == (a: AppHistoryRow, b: AppHistoryRow) -> Bool {
        a.bundleID == b.bundleID && a.cpuTimeSeconds == b.cpuTimeSeconds
            && a.networkBytes == b.networkBytes
    }
}

// MARK: - Sorting

enum SortDirection {
    case ascending, descending

    var flipped: SortDirection { self == .ascending ? .descending : .ascending }

    /// Chevron shown in the active column header.
    var symbol: String { self == .ascending ? "chevron.up" : "chevron.down" }
}
