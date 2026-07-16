import Combine
import Foundation

/// What the fast path produces every tick.
private struct Snapshot {
    var cpu: CPUStats
    var memory: MemoryStats
    var disks: [DiskStats]
    var networks: [NetworkStats]
    var gpus: [GPUStats]
    var processes: [ProcRow]
    var appHistory: [AppHistoryRow]
}

/// The subprocess-backed samplers, which answer in seconds rather than
/// milliseconds and whose answers barely move.
private struct SlowSnapshot {
    var services: [ServiceRow]
    var startupItems: [StartupRow]
    var users: [UserRow]
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

    func snapshot() -> Snapshot {
        let processes = process.sample()
        history.record(processes)
        lastProcesses = processes

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
            appHistory: history.rows()
        )
    }

    /// Runs on its own queue. UserSampler needs the process list, and reusing the
    /// last fast snapshot avoids a second full enumeration just to attribute rows
    /// to accounts.
    func slowSnapshot() -> SlowSnapshot {
        SlowSnapshot(
            services: service.sample(),
            startupItems: startup.sample(),
            users: user.sample(processes: lastProcesses)
        )
    }

    /// Written on the fast queue, read on the slow one — hence the lock.
    private var lastProcesses: [ProcRow] {
        get { lock.withLock { _lastProcesses } }
        set { lock.withLock { _lastProcesses = newValue } }
    }
    private var _lastProcesses: [ProcRow] = []
    private let lock = NSLock()

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

    /// True once the first fast sample lands, so tables can say "loading" instead
    /// of rendering as an empty list that looks broken.
    @Published private(set) var hasLoaded = false

    /// The slow set answers seconds later than the fast one, so the tabs backed by
    /// it need their own flag — sharing `hasLoaded` would show them as empty.
    @Published private(set) var hasLoadedSlow = false

    /// launchctl / system_profiler / login-item scans are subprocesses costing
    /// seconds between them, and their answers barely move. They run on their own
    /// queue at this cadence so they can never stall the 1 Hz fast path.
    private static let slowInterval: TimeInterval = 10

    private let samplers = SamplerSet()
    private let queue = DispatchQueue(label: "com.taskmanager.sampling", qos: .utility)
    private let slowQueue = DispatchQueue(label: "com.taskmanager.sampling.slow", qos: .background)
    private var timer: Timer?
    private var slowTimer: Timer?
    private var sampling = false
    private var samplingSlow = false

    private init() {}

    /// Starts the timer at `interval`, unless the user has paused updates —
    /// in which case sampling stays fully stopped until `refreshNow()` or an
    /// explicit resume. This lets every call site just pass the configured
    /// cadence without re-checking `AppState.shared.isPaused` itself.
    func start(interval: TimeInterval) {
        stop()
        guard !AppState.shared.isPaused else { return }

        fire()
        fireSlow()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let slow = Timer(timeInterval: Self.slowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireSlow() }
        }
        slow.tolerance = Self.slowInterval * 0.5
        RunLoop.main.add(slow, forMode: .common)
        self.slowTimer = slow
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        slowTimer?.invalidate()
        slowTimer = nil
    }

    func refreshNow() {
        fire()
        fireSlow()
    }

    // MARK: - Tick

    private func fire() {
        // A tick can outlast the timer interval; dropping the overlap keeps the
        // queue from growing a backlog of stale work.
        guard !sampling else { return }
        sampling = true

        queue.async { [samplers] in
            let snapshot = samplers.snapshot()
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    private func fireSlow() {
        guard !samplingSlow else { return }
        samplingSlow = true

        slowQueue.async { [samplers] in
            let snapshot = samplers.slowSnapshot()
            Task { @MainActor [weak self] in
                self?.applySlow(snapshot)
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
        sampling = false
        hasLoaded = true
    }

    private func applySlow(_ snapshot: SlowSnapshot) {
        services = snapshot.services
        startupItems = snapshot.startupItems
        users = snapshot.users
        samplingSlow = false
        hasLoadedSlow = true
    }
}
