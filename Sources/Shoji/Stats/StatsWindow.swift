import AppKit

/// Mod+I: live statistics in a pop-up window — Shoji's own CPU and memory, the apps whose windows
/// it manages, workspaces, the system, and the build. Samples once a second, only while open.
/// (From MacLucent's Stats tile; Shoji manages other apps' windows, so "shells" became "apps".)
@MainActor
final class StatsWindow: NSObject, NSWindowDelegate {
    private static var current: StatsWindow?

    /// Mod+I: open it as a tile in the current workspace; if it's open, go to it; if it's
    /// already focused, close it.
    static func toggle() {
        let wm = WindowManager.shared
        if let s = current, s.window.isVisible {
            if wm?.isFocused(s.window) ?? s.window.isKeyWindow {
                s.window.performClose(nil)
            } else {
                wm?.tileOwnWindow(s.window) // already tiled: focuses it (switching workspace if needed)
            }
            return
        }
        let s = current ?? StatsWindow()
        current = s
        NSApp.activate(ignoringOtherApps: true)
        s.window.makeKeyAndOrderFront(nil)
        s.start()
        // A tile like any app's window (Shoji's other windows float).
        DispatchQueue.main.async { wm?.tileOwnWindow(s.window) }
    }

    let window: ShojiWindow
    private let root = FlippedView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let sampler = AppsSampler()
    private var timer: Timer?
    private var c: Config { .shared }

    private let heading = NSTextField(labelWithString: "Shoji")
    private let subheading = NSTextField(labelWithString: "")
    private let shojiCPU = StatTile(label: "Shoji CPU")       // Shoji, Shoji Machines + its VMs, Shoji Containers
    private let shojiMemory = StatTile(label: "Shoji memory")
    private let appsCPU = StatTile(label: "Managed apps CPU")
    private let appsMemory = StatTile(label: "Managed apps memory")
    private let systemCPU = StatTile(label: "System CPU")
    private let systemMemory = StatTile(label: "System memory")
    private let windowsTile = StatTile(label: "Managed windows")
    private let diskTile = StatTile(label: "Disk free")
    private var tiles: [StatTile] { [shojiCPU, shojiMemory, appsCPU, appsMemory, systemCPU, systemMemory, windowsTile, diskTile] }
    private let familyTable = InfoTable(title: "Shoji apps")
    private let workspacesTable = InfoTable(title: "Workspaces")
    private let appsTable = InfoTable(title: "Apps")
    private let systemTable = InfoTable(title: "System")
    private let buildTable = InfoTable(title: "Build")
    private var tables: [InfoTable] { [familyTable, workspacesTable, appsTable, systemTable, buildTable] }
    private let launched = ProcStats.startTime(getpid()) ?? Date()

    override init() {
        window = ShojiWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Shoji Stats"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        window.setFrameAutosaveName("ShojiStats")
        if !window.setFrameUsingName("ShojiStats") { window.center() }
        root.wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        root.addSubview(scroll)
        root.onLayout = { [weak self] in self?.layout() }

        heading.font = c.uiFont(22, weight: .semibold)
        subheading.font = c.uiFont(12.5, weight: .regular)
        [heading, subheading].forEach(doc.addSubview)
        tiles.forEach(doc.addSubview)
        tables.forEach(doc.addSubview)

        // CPU on a % axis with a floor so idle noise isn't magnified; memory auto-scaled.
        let percent: (Double) -> String = { String(format: "%.1f%%", $0) }
        shojiCPU.sparkline.format = percent
        shojiCPU.sparkline.minimumCeiling = 10
        appsCPU.sparkline.format = percent
        appsCPU.sparkline.minimumCeiling = 50
        systemCPU.sparkline.format = percent
        systemCPU.sparkline.minimumCeiling = 100
        shojiMemory.sparkline.format = { Self.bytes($0) }
        appsMemory.sparkline.format = { Self.bytes($0) }
        shojiMemory.sparkline.minimumCeiling = 32 * 1_048_576
        appsMemory.sparkline.minimumCeiling = 256 * 1_048_576
        for t in [systemMemory, windowsTile, diskTile] { t.sparkline.isHidden = true }
        systemMemory.showsMeter = true
        diskTile.showsMeter = true

        fillStatic()
        applyColors()
        NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyColors() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate() // nothing samples while it's closed
        timer = nil
        WindowManager.shared?.releaseOwnWindow(window)
    }

    // MARK: Updating

    /// Theme colours plus Settings → Windows: translucent by `windowOpacity`, and no title bar or
    /// buttons with `hideTitleBars` (like kitty and Shoji Machines).
    private func applyColors() {
        root.appearance = c.appearance
        window.applyWindowSettings(background: root)
        heading.textColor = c.text
        subheading.textColor = c.subtext
        tiles.forEach { $0.refreshColors() }
        tables.forEach { $0.refreshColors() }
    }

    private func tick() {
        let wm = WindowManager.shared // nil in --preview-stats
        let managed = wm?.allWindows ?? []
        sampler.sample(pids: Set(managed.map(\.pid)))
        let s = sampler
        subheading.stringValue = "\(Self.versionString) · up \(Self.duration(Date().timeIntervalSince(launched))) · pid \(getpid())"

        // Shoji and its companions (Shoji Machines with its VMs, Shoji Containers) count as one.
        let parts = s.family.filter { $0.processes > 0 }
        let vms = s.family.first { $0.name == "VMs" }?.processes ?? 0
        let familyText = parts.count > 1 ? parts.map { $0.name == "VMs" ? "\(vms) VM\(vms == 1 ? "" : "s")" : $0.name }.joined(separator: " + ")
                                         : "of one core"
        shojiCPU.set(value: s.shojiCPU.last.map { String(format: "%.1f%%", $0) } ?? "–", detail: familyText, series: s.shojiCPU)
        shojiMemory.set(value: s.shojiMemory.last.map { Self.bytes($0) } ?? "–",
                        detail: parts.count > 1 ? "\(parts.count) parts · physical footprint" : "physical footprint", series: s.shojiMemory)
        familyTable.set(columns: ["Part", "Processes", "CPU", "Memory"], rows: s.family.map { f in
            [f.name, f.processes == 0 ? "off" : "\(f.processes)", f.processes == 0 ? "–" : String(format: "%.1f%%", f.cpu),
             f.processes == 0 ? "–" : Self.bytes(Double(f.memory))]
        }, numeric: [1, 2, 3])
        appsCPU.set(value: s.appsCPU.last.map { String(format: "%.0f%%", $0) } ?? "–",
                    detail: "\(s.apps.count) app\(s.apps.count == 1 ? "" : "s") · of one core", series: s.appsCPU)
        appsMemory.set(value: s.appsMemory.last.map { Self.bytes($0) } ?? "–", detail: "physical footprint", series: s.appsMemory)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        systemCPU.set(value: s.systemCPU.last.map { String(format: "%.0f%%", $0) } ?? "–", detail: "all \(cores) cores", series: s.systemCPU)
        let total = ProcessInfo.processInfo.physicalMemory
        systemMemory.set(value: Self.bytes(Double(s.systemMemoryUsed)), detail: "of \(Self.bytes(Double(total)))", series: [])
        systemMemory.meter.fraction = total > 0 ? Double(s.systemMemoryUsed) / Double(total) : 0
        if let d = HostStats.disk() {
            diskTile.set(value: Self.bytes(Double(d.free)), detail: "of \(Self.bytes(Double(d.total)))", series: [])
            diskTile.meter.fraction = d.total > 0 ? 1 - Double(d.free) / Double(d.total) : 0
        }
        let tiled = managed.filter { !$0.isFloating }.count
        windowsTile.set(value: "\(managed.count)", detail: "\(tiled) tiled · \(managed.count - tiled) floating", series: [])

        // Workspaces: windows on each, by app.
        let wsRows = (wm?.workspaces ?? []).filter { !$0.isEmpty || $0 === wm?.current }.map { ws -> [String] in
            var byApp: [String: Int] = [:]
            for w in ws.windows { byApp[w.appName, default: 0] += 1 }
            let detail = byApp.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
            let mode = ws.fullscreen != nil ? "fullscreen" : (ws.isFloatingMode ? "floating" : "dwindle")
            return ["\(ws.index % 10)\(ws === wm?.current ? "  •" : "")", mode, "\(ws.windows.count)", detail.isEmpty ? "empty" : detail]
        }
        workspacesTable.set(columns: ["Workspace", "Layout", "Windows", "Apps"], rows: wsRows, numeric: [2])

        // Apps: each managed app's windows, workspaces and use, busiest first.
        let appRows = s.apps.sorted { $0.cpu > $1.cpu }.map { a -> [String] in
            let mine = managed.filter { $0.pid == a.pid }
            let spaces = Set(mine.map(\.workspace)).sorted().map { "\($0 % 10)" }.joined(separator: " ")
            return [a.name, "\(mine.count)", spaces, String(format: "%.1f%%", a.cpu), Self.bytes(Double(a.memory))]
        }
        appsTable.set(columns: ["App", "Windows", "Workspaces", "CPU", "Memory"], rows: appRows, numeric: [1, 3, 4],
                      empty: "No managed windows")

        let p = ProcessInfo.processInfo
        let load = HostStats.loadAverage()
        systemTable.set(columns: ["", ""], rows: [
            ["macOS", p.operatingSystemVersionString],
            ["Chip", HostStats.sysctlString("machdep.cpu.brand_string") ?? "–"],
            ["Model", HostStats.sysctlString("hw.model") ?? "–"],
            ["Cores", "\(p.activeProcessorCount)"],
            ["Memory", Self.bytes(Double(p.physicalMemory))],
            ["Load average", String(format: "%.2f  %.2f  %.2f", load.0, load.1, load.2)],
            ["System uptime", Self.duration(p.systemUptime)],
        ], headerless: true)
        layout()
    }

    private func fillStatic() {
        let info = Bundle.main.infoDictionary ?? [:]
        func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
        buildTable.set(columns: ["", ""], rows: [
            ["Version", Self.versionString],
            ["Commit", info["ShojiGitCommit"] as? String ?? "dev build"],
            ["Bundle", Bundle.main.bundlePath.hasSuffix(".app") ? short(Bundle.main.bundlePath) : "not bundled (swift run)"],
            ["Settings", short(Config.settingsURL.path)],
            ["Log", short(NSHomeDirectory() + "/Library/Logs/Shoji/shoji.log")],
            ["Modifier", Config.shared.modifierKey.title],
        ], headerless: true)
    }

    /// `--preview-stats out.png`: render the window's contents offscreen (two samples a second
    /// apart), without showing anything.
    static func renderPreview(to path: String) {
        let s = StatsWindow()
        s.root.frame = CGRect(x: 0, y: 0, width: 960, height: 900)
        s.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            s.tick()
            s.root.layoutSubtreeIfNeeded()
            let rep = s.root.bitmapImageRepForCachingDisplay(in: s.root.bounds)!
            s.root.cacheDisplay(in: s.root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    // MARK: Layout

    private func layout() {
        scroll.frame = root.bounds
        let width = max(300, min(980, root.bounds.width - 40))
        let x0 = (root.bounds.width - width) / 2
        // Below the title bar, or below where it would be when hidden.
        var y: CGFloat = max(22, window.titlebarInset + 8)
        heading.sizeToFit()
        heading.frame.origin = CGPoint(x: x0, y: y)
        y += heading.frame.height + 2
        subheading.frame = CGRect(x: x0, y: y, width: width, height: 18)
        y += 32
        let gap: CGFloat = 12
        let columns = max(1, min(4, Int((width + gap) / (210 + gap))))
        let tileW = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let tileH: CGFloat = 112
        for (i, t) in tiles.enumerated() {
            t.frame = CGRect(x: x0 + CGFloat(i % columns) * (tileW + gap), y: y + CGFloat(i / columns) * (tileH + gap),
                             width: tileW, height: tileH)
        }
        y += CGFloat((tiles.count + columns - 1) / columns) * (tileH + gap) + 12
        for table in [familyTable, workspacesTable, appsTable] {
            table.frame = CGRect(x: x0, y: y, width: width, height: table.preferredHeight)
            y += table.preferredHeight + 18
        }
        if width >= 640 {
            let half = (width - gap) / 2
            systemTable.frame = CGRect(x: x0, y: y, width: half, height: systemTable.preferredHeight)
            buildTable.frame = CGRect(x: x0 + half + gap, y: y, width: half, height: buildTable.preferredHeight)
            y += max(systemTable.preferredHeight, buildTable.preferredHeight) + 18
        } else {
            for table in [systemTable, buildTable] {
                table.frame = CGRect(x: x0, y: y, width: width, height: table.preferredHeight)
                y += table.preferredHeight + 18
            }
        }
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 12)
    }

    // MARK: Formatting

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "dev"
        return info["CFBundleVersion"].map { "v\(v) (\($0))" } ?? "v\(v)"
    }

    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v, i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        return i == 0 ? "\(Int(x)) B" : String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// Samples the Shoji family, the managed apps and the system once a second; keeps a minute of history.
/// The family is Shoji, Shoji Machines and the VMs it runs, and Shoji Containers — counted as one in
/// the Shoji tiles and left out of the managed apps.
@MainActor
final class AppsSampler {
    struct App {
        let pid: pid_t
        let name: String
        let cpu: Double      // % of one core
        let memory: UInt64
    }
    struct Part {
        let name: String
        let processes: Int
        let cpu: Double
        let memory: UInt64
    }
    static let historyLength = 60

    private(set) var shojiCPU: [Double] = []
    private(set) var shojiMemory: [Double] = []
    private(set) var appsCPU: [Double] = []
    private(set) var appsMemory: [Double] = []
    private(set) var systemCPU: [Double] = []
    private(set) var apps: [App] = []
    private(set) var family: [Part] = []
    private(set) var systemMemoryUsed: UInt64 = 0

    private var lastWall: UInt64 = 0
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastHostTicks: (busy: UInt64, total: UInt64)?
    private var primed = false

    func sample(pids: Set<pid_t>) {
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Double(now &- lastWall)
        defer { lastWall = now; primed = true }
        var seen: [pid_t: UInt64] = [:]
        /// CPU (% of one core since the last sample) and footprint of a process.
        func use(_ pid: pid_t) -> (cpu: Double, memory: UInt64)? {
            guard let u = ProcStats.usage(pid) else { return nil }
            seen[pid] = u.cpuNs
            var cpu = 0.0
            if primed, let prev = lastCPU[pid], u.cpuNs >= prev, wall > 0 { cpu = Double(u.cpuNs - prev) / wall * 100 }
            return (cpu, u.footprint)
        }

        // The family.
        func running(_ bundleID: String) -> [pid_t] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        }
        let machines = running("dev.shoji.Machines")
        let vms = ProcStats.virtualMachineProcesses(responsibleFor: Set(machines))
        let groups: [(String, [pid_t])] = [("Shoji", [getpid()]), ("Shoji Machines", machines), ("VMs", vms),
                                           ("Shoji Containers", running("dev.shoji.Containers"))]
        var parts: [Part] = []
        var familyCPU = 0.0, familyMem: UInt64 = 0
        var familyPIDs = Set<pid_t>()
        for (name, list) in groups {
            var cpu = 0.0, mem: UInt64 = 0, n = 0
            for pid in list { if let u = use(pid) { cpu += u.cpu; mem += u.memory; n += 1; familyPIDs.insert(pid) } }
            parts.append(Part(name: name, processes: n, cpu: cpu, memory: mem))
            familyCPU += cpu
            familyMem += mem
        }
        family = parts
        if primed { push(&shojiCPU, familyCPU) }
        push(&shojiMemory, Double(familyMem))

        // The managed apps (other than the family).
        var list: [App] = []
        var totalCPU = 0.0, totalMem: UInt64 = 0
        for pid in pids where !familyPIDs.contains(pid) {
            guard let u = use(pid) else { continue }
            totalCPU += u.cpu
            totalMem += u.memory
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ProcStats.name(pid) ?? "pid \(pid)"
            list.append(App(pid: pid, name: name, cpu: u.cpu, memory: u.memory))
        }
        lastCPU = seen
        apps = list
        if primed { push(&appsCPU, totalCPU) }
        push(&appsMemory, Double(totalMem))

        if let ticks = HostStats.cpuTicks() {
            if let last = lastHostTicks, ticks.total > last.total {
                push(&systemCPU, Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100)
            }
            lastHostTicks = ticks
        }
        systemMemoryUsed = HostStats.memoryUsed() ?? systemMemoryUsed
    }

    private func push(_ series: inout [Double], _ v: Double) {
        series.append(max(0, v))
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }
}
