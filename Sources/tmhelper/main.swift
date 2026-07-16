// tmhelper — the privileged sampling helper.
//
// Installed setuid-root at /Library/Application Support/TaskManager/tmhelper so the
// unprivileged app can read stats for processes it does not own. This is the same
// mechanism /bin/ps uses; without it proc_pidinfo returns nothing for root-owned pids.
//
// Because this binary runs as root for any caller, it is deliberately tiny and does
// exactly two things: dump process stats, and signal a pid. It never execs, never
// touches the filesystem, and never interprets a path. Read the protocol below before
// adding anything — every new verb here is a new root-privileged attack surface.
//
// Protocol (line-based over stdin/stdout):
//   SAMPLE            -> "<pid> <cpu_ns> <threads> <footprint> <diskr> <diskw> <fds>" per line, then "END"
//   KILL <pid> <sig>  -> "OK" | "ERR <errno>"     sig ∈ {TERM, KILL, STOP, CONT}
//   PING              -> "PONG <version>"
//   QUIT              -> exits

import Darwin
import Foundation

let helperVersion = 1

/// proc_taskinfo reports CPU in mach absolute time units, not nanoseconds. The
/// factor is 1 on Intel and 125/3 on Apple Silicon, so the raw value is converted
/// here — the protocol promises nanoseconds and the client must not have to care
/// which machine the helper ran on.
let machToNanos: Double = {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
    return Double(timebase.numer) / Double(timebase.denom)
}()

// MARK: - Caller authorisation

/// Only admins may drive this helper. They can already reach root via sudo, so this
/// grants them nothing new — but it stops a standard user on a shared Mac from
/// signalling root processes just because the setuid bit is set.
func callerIsAdmin() -> Bool {
    let uid = getuid()          // real uid — the invoking user, not the effective root
    if uid == 0 { return true }

    guard let pw = getpwuid(uid), let name = String(validatingUTF8: pw.pointee.pw_name) else {
        return false
    }

    // Darwin's getgrouplist takes int, not gid_t. 64 is well above the practical
    // group limit, so a single call is enough.
    var groups = [Int32](repeating: 0, count: 64)
    var count = Int32(groups.count)
    guard groups.withUnsafeMutableBufferPointer({ buf in
        name.withCString { cName in
            getgrouplist(cName, Int32(bitPattern: pw.pointee.pw_gid), buf.baseAddress, &count) != -1
        }
    }) else { return false }

    guard let admin = getgrnam("admin") else { return false }
    let adminGID = Int32(bitPattern: admin.pointee.gr_gid)
    return groups.prefix(Int(count)).contains(adminGID)
}

guard callerIsAdmin() else {
    FileHandle.standardError.write(Data("tmhelper: caller is not an administrator\n".utf8))
    exit(77)   // EX_NOPERM
}

// MARK: - Sampling

func allPIDs() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

    // sysctl rewrites `size` with what it actually returned, which may be smaller
    // than the first call reported if processes exited in between.
    return procs.prefix(size / stride).map { $0.kp_proc.p_pid }
}

func fileDescriptorCount(_ pid: pid_t) -> Int {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return 0 }
    return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
}

func sample(into out: inout String) {
    for pid in allPIDs() {
        var ti = proc_taskinfo()
        let tiSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }

        let cpuNS = UInt64(Double(ti.pti_total_user &+ ti.pti_total_system) * machToNanos)

        // rusage carries the numbers Activity Monitor shows; it can fail for short-lived
        // pids, in which case we fall back to resident size and zero I/O.
        var footprint = ti.pti_resident_size
        var diskRead: UInt64 = 0
        var diskWrite: UInt64 = 0
        var rusage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &rusage) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        if ok {
            footprint = rusage.ri_phys_footprint
            diskRead = rusage.ri_diskio_bytesread
            diskWrite = rusage.ri_diskio_byteswritten
        }

        out += "\(pid) \(cpuNS) \(ti.pti_threadnum) \(footprint) \(diskRead) \(diskWrite) \(fileDescriptorCount(pid))\n"
    }
    out += "END\n"
}

// MARK: - Signalling

let allowedSignals: [String: Int32] = [
    "TERM": SIGTERM,
    "KILL": SIGKILL,
    "STOP": SIGSTOP,
    "CONT": SIGCONT,
]

func handleKill(_ parts: [Substring]) -> String {
    guard parts.count == 3,
          let pid = pid_t(parts[1]),
          pid > 0,
          let sig = allowedSignals[String(parts[2])]
    else { return "ERR \(EINVAL)" }

    return kill(pid, sig) == 0 ? "OK" : "ERR \(errno)"
}

// MARK: - Loop

setvbuf(stdout, nil, _IOFBF, 1 << 16)

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: " ")
    guard let verb = parts.first else { continue }

    switch verb {
    case "SAMPLE":
        var out = ""
        out.reserveCapacity(64 * 1024)
        sample(into: &out)
        print(out, terminator: "")
    case "KILL":
        print(handleKill(parts))
    case "PING":
        print("PONG \(helperVersion)")
    case "QUIT":
        exit(0)
    default:
        print("ERR \(EINVAL)")
    }
    fflush(stdout)
}
