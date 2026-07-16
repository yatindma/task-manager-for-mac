import Combine
import Foundation

/// Everything the samplers produce in one tick.
private struct Snapshot {
    var cpu: CPUStats
    var memory: MemoryStats
    var disks: [DiskStats]
    var networks: [NetworkStats]
    var gpus: [GPUStats]
    var processes: [ProcRow]
    var appHistory: [AppHistoryRow]
    /// Only populated on slow ticks; nil means "keep what is on screen".
    var services: [ServiceRow]?
    var startupItems: [StartupRow]?
    var users: [UserRow]?
}

/// Holds the samplers off the main actor. Every method here runs on the
/// monitor's serial sampling queue, which is what gives the samplers their
/// one-caller-at-a-time guarantee.
private final class SamplerSet {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let process = ProcessSampler()
    private let service = ServiceSampler()
    private let startup = StartupSampler()
    private let user = UserSampler()
    private let history = AppHistoryStore()

    func snapshot(includeSlow: Bool) -> Snapshot {
        let processes = process.sample()
        history.record(processes)

        var cpuStats = cpu.sample()
        cpuStats.processCount = countProcesses(processes)
        cpuStats.threadCount = countThreads(processes)
        cpuStats.handleCount = countHandles(processes)

        return Snapshot(
            cpu: cpuStats,
            memory: memory.sample(),
            disks: disk.sample(),
            networks: network.sample(),
            gpus: gpu.sample(),
            processes: processes,
            appHistory: history.rows(),
            services: includeSlow ? service.sample() : nil,
            startupItems: includeSlow ? startup.sample() : nil,
            users: includeSlow ? user.sample(processes: processes) : nil
        )
    }

    private func countProcesses(_ rows: [ProcRow]) -> Int {
        rows.reduce(0) { $0 + 1 + countProcesses($1.children) }
    }

    private func countThreads(_ rows: [ProcRow]) -> Int {
        rows.reduce(0) { $0 + $1.threads + countThreads($1.children) }
    }

    private func countHandles(_ rows: [ProcRow]) -> Int {
        rows.reduce(0) { $0 + $1.handles + countHandles($1.children) }
    }
}

/// Drives every sampler on a timer and publishes the results to the UI.
@MainActor
final class SystemMonitor: ObservableObject {

    static let shared = SystemMonitor()

    @Published var cpu = CPUStats()
    @Published var memory = MemoryStats()
    @Published var disks: [DiskStats] = []
    @Published var networks: [NetworkStats] = []
    @Published var gpus: [GPUStats] = []
    @Published var processes: [ProcRow] = []
    @Published var services: [ServiceRow] = []
    @Published var startupItems: [StartupRow] = []
    @Published var users: [UserRow] = []
    @Published var appHistory: [AppHistoryRow] = []

    /// launchctl / who / login-item scans cost tens of milliseconds of subprocess
    /// each, and their answers barely move. Run them once per this many ticks.
    private static let slowTickStride = 10

    private let samplers = SamplerSet()
    private let queue = DispatchQueue(label: "com.taskmanager.sampling", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var sampling = false

    private init() {}

    /// Starts the timer at `interval`, unless the user has paused updates —
    /// in which case sampling stays fully stopped until `refreshNow()` or an
    /// explicit resume. This lets every call site just pass the configured
    /// cadence without re-checking `AppState.shared.isPaused` itself.
    func start(interval: TimeInterval) {
        stop()
        guard !AppState.shared.isPaused else { return }
        // First tick immediately so the window never opens on empty tables.
        fire(forceSlow: true)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire(forceSlow: false) }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        fire(forceSlow: true)
    }

    // MARK: - Tick

    private func fire(forceSlow: Bool) {
        // A slow tick can outlast the timer interval; dropping the overlap keeps
        // the queue from growing a backlog of stale work.
        guard !sampling else { return }
        sampling = true

        let includeSlow = forceSlow || tick % Self.slowTickStride == 0
        tick &+= 1

        queue.async { [samplers] in
            let snapshot = samplers.snapshot(includeSlow: includeSlow)
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        cpu = snapshot.cpu
        memory = snapshot.memory
        disks = snapshot.disks
        networks = snapshot.networks
        gpus = snapshot.gpus
        processes = snapshot.processes
        appHistory = snapshot.appHistory
        if let services = snapshot.services { self.services = services }
        if let startupItems = snapshot.startupItems { self.startupItems = startupItems }
        if let users = snapshot.users { self.users = users }
        sampling = false
    }
}
