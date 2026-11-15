import Foundation
import Darwin

/// Low-level readers for process and system statistics.
enum ProcStats {
    struct Usage {
        /// Total user + system CPU time, in nanoseconds.
        var cpuNs: UInt64
        /// Physical footprint (what Activity Monitor calls "Memory"), in bytes.
        var footprint: UInt64
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        // rusage CPU times are in Mach absolute-time units (not ns on Apple silicon).
        let ticks = info.ri_user_time &+ info.ri_system_time
        return Usage(cpuNs: ticks &* timebase.numer / timebase.denom, footprint: info.ri_phys_footprint)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(count) * 2 + 8)
        let n = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(buf.prefix(Int(n))).filter { $0 > 0 } : []
    }

    /// `pid` and all of its descendants.
    static func tree(_ pid: pid_t) -> [pid_t] {
        var out: [pid_t] = [pid]
        var i = 0
        while i < out.count, out.count < 512 {
            out += children(of: out[i])
            i += 1
        }
        return out
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    /// Virtualization.framework runs each VM in its own XPC helper (parent: launchd). The app that
    /// started it is its "responsible" process — how Shoji Machines' VMs are told apart from, say,
    /// Docker Desktop's. (`responsibility_get_pid_responsible_for_pid` is private but long-lived;
    /// looked up at runtime, so without it Shoji just counts no VMs.)
    static func virtualMachineProcesses(responsibleFor owners: Set<pid_t>) -> [pid_t] {
        guard !owners.isEmpty, let responsible = responsiblePID else { return [] }
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
                  String(cString: buf).contains("com.apple.Virtualization.VirtualMachine") else { return false }
            return owners.contains(responsible(pid))
        }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
}

enum HostStats {
    /// Cumulative CPU ticks across all cores: (busy, total).
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (user, system, idle, nice)
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Memory in use, computed like Activity Monitor's "Memory Used" (app + wired + compressed).
    static func memoryUsed() -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(info.internal_page_count) &- UInt64(info.purgeable_count)
        return (app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
    }

    static func loadAverage() -> (Double, Double, Double) {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? (l[0], l[1], l[2]) : (0, 0, 0)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func disk() -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }
}
