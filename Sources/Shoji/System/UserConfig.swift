import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// shoji.conf was (re)loaded.
    static let userConfigDidChange = Notification.Name("ShojiUserConfigDidChange")
}

/// ~/.config/shoji/shoji.conf — the hyprland.conf-style part of Shoji's configuration: keybindings,
/// window rules, workspace layouts and programs to start. Reloaded whenever it's saved. (Settings,
/// Mod+, , keeps the look: theme, gaps, modifier, window options.)
@MainActor
final class UserConfig {
    static let shared = UserConfig()

    struct Bind {
        let modifiers: UInt32     // Carbon modifier mask
        let key: Key
        let modLabel: String
        let dispatcher: String
        let argument: String
        let line: Int
    }

    struct Rule {
        enum Effect { case float, tile, workspace(Int, silent: Bool), size(CGSize), center }
        let effect: Effect
        let app: String?          // app name or bundle id, case-insensitive
        let title: NSRegularExpression?
    }

    /// What the rules matching one window say.
    struct Applied {
        var float = false, tile = false, center = false, silent = false
        var workspace: Int?
        var size: CGSize?
    }

    private(set) var binds: [Bind] = []
    private(set) var rules: [Rule] = []
    private(set) var floatingWorkspaces: Set<Int> = []
    private(set) var errors: [String] = []
    private var exec: [String] = []
    private var execOnce: [String] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var lastModified: Date?
    private var reloadWork: DispatchWorkItem?

    static var url: URL { Config.directory.appendingPathComponent("shoji.conf") }

    // MARK: Loading

    /// First load at startup: writes the commented default file if there's none, runs
    /// `exec-once` (once per login) and `exec`, and starts watching the file.
    func start() {
        if !FileManager.default.fileExists(atPath: Self.url.path) {
            try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
            try? Self.defaultFile.write(to: Self.url, atomically: true, encoding: .utf8)
        }
        load()
        runExecOnce()
        exec.forEach(Self.run)
        watch()
    }

    func load() {
        let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        lastModified = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
        parse(text)
        if !errors.isEmpty {
            errors.forEach { ShojiLog.write("shoji.conf: \($0)") }
            ConfigErrorBanner.show(errors)
        } else {
            ConfigErrorBanner.hide()
        }
        NotificationCenter.default.post(name: .userConfigDidChange, object: nil)
    }

    /// `Shoji --check-config`: parse shoji.conf and describe what it says (no side effects).
    func check() -> String {
        parse((try? String(contentsOf: Self.url, encoding: .utf8)) ?? "")
        var out = ["\(Self.url.path)"]
        out += binds.map { "bind      \($0.modLabel)\($0.key.label) → \($0.dispatcher) \($0.argument)" }
        out += rules.map { r in
            let match = [r.app.map { "app:\($0)" }, r.title.map { "title:\($0.pattern)" }].compactMap { $0 }.joined(separator: " ")
            return "rule      \(r.effect) for \(match)"
        }
        out += floatingWorkspaces.sorted().map { "workspace \($0) floating" }
        out += execOnce.map { "exec-once \($0)" } + exec.map { "exec      \($0)" }
        out += errors.map { "ERROR     \($0)" }
        out.append(errors.isEmpty ? "OK" : "\(errors.count) error(s)")
        return out.joined(separator: "\n")
    }

    private func parse(_ text: String) {
        var binds: [Bind] = [], rules: [Rule] = [], floating = Set<Int>(), errors: [String] = []
        var exec: [String] = [], execOnce: [String] = []
        var vars: [String: String] = [:]
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = n + 1
            // Comments: `#` to the end of the line (`##` is a literal #).
            var line = raw.replacingOccurrences(of: "##", with: "\u{0}")
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.replacingOccurrences(of: "\u{0}", with: "#").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let eq = line.firstIndex(of: "=") else { errors.append("line \(lineNo): expected key = value"); continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("$") { vars[key] = value; continue }
            for (name, v) in vars.sorted(by: { $0.key.count > $1.key.count }) { value = value.replacingOccurrences(of: name, with: v) }
            switch key {
            case "bind":
                switch Self.parseBind(value, line: lineNo) {
                case .success(let b): binds.append(b)
                case .failure(let e): errors.append("line \(lineNo): \(e.message)")
                }
            case "windowrule":
                switch Self.parseRule(value) {
                case .success(let r): rules.append(r)
                case .failure(let e): errors.append("line \(lineNo): \(e.message)")
                }
            case "workspace":
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard let i = Int(parts.first ?? ""), (1...10).contains(i) else { errors.append("line \(lineNo): workspace = <1-10>, floating"); continue }
                if parts.dropFirst().contains("floating") { floating.insert(i) }
                else { errors.append("line \(lineNo): unknown workspace option \(parts.dropFirst().joined(separator: ", "))") }
            case "exec": exec.append(value)
            case "exec-once": execOnce.append(value)
            default: errors.append("line \(lineNo): unknown keyword \"\(key)\"")
            }
        }
        self.binds = binds
        self.rules = rules
        self.floatingWorkspaces = floating
        self.errors = errors
        self.exec = exec
        self.execOnce = execOnce
    }

    struct ParseError: Error { let message: String }

    /// `MODS, KEY, dispatcher[, argument]`
    private static func parseBind(_ value: String, line: Int) -> Result<Bind, ParseError> {
        let parts = value.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return .failure(ParseError(message: "bind = MODS, KEY, dispatcher[, argument]")) }
        var mods: UInt32 = 0
        var label = ""
        let c = Config.shared
        for token in parts[0].uppercased().split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "_" }) {
            switch token {
            case "$MOD", "MOD", "SUPER": mods |= c.modifierKey.carbon; label += c.modSymbol
            case "SHIFT": mods |= UInt32(shiftKey); label += "⇧"
            case "CTRL", "CONTROL": mods |= UInt32(controlKey); label += "⌃"
            case "ALT", "OPTION", "OPT": mods |= UInt32(optionKey); label += "⌥"
            case "CMD", "COMMAND": mods |= UInt32(cmdKey); label += "⌘"
            default: return .failure(ParseError(message: "unknown modifier \(token)"))
            }
        }
        guard mods != 0 else { return .failure(ParseError(message: "a bind needs at least one modifier")) }
        guard let key = Key.named(parts[1]) else { return .failure(ParseError(message: "unknown key \(parts[1])")) }
        let dispatcher = parts[2].lowercased()
        guard Dispatcher.names.contains(dispatcher) else { return .failure(ParseError(message: "unknown dispatcher \(parts[2])")) }
        return .success(Bind(modifiers: mods, key: key, modLabel: label, dispatcher: dispatcher,
                             argument: parts.count > 3 ? parts[3] : "", line: line))
    }

    /// `EFFECT, app:<name|bundle id>[, title:<regex>]`
    private static func parseRule(_ value: String) -> Result<Rule, ParseError> {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return .failure(ParseError(message: "windowrule = EFFECT, app:<name>[, title:<regex>]")) }
        let words = parts[0].split(separator: " ").map { $0.lowercased() }
        let effect: Rule.Effect
        switch words.first {
        case "float": effect = .float
        case "tile": effect = .tile
        case "center": effect = .center
        case "workspace":
            guard words.count >= 2, let n = Int(words[1]), (1...10).contains(n) else {
                return .failure(ParseError(message: "workspace <1-10> [silent]"))
            }
            effect = .workspace(n, silent: words.contains("silent"))
        case "size":
            guard words.count == 3, let w = Double(words[1]), let h = Double(words[2]) else {
                return .failure(ParseError(message: "size <width> <height>"))
            }
            effect = .size(CGSize(width: w, height: h))
        default: return .failure(ParseError(message: "unknown rule \(parts[0])"))
        }
        var app: String?, title: NSRegularExpression?
        for m in parts.dropFirst() {
            if m.lowercased().hasPrefix("app:") {
                app = String(m.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if m.lowercased().hasPrefix("title:") {
                guard let re = try? NSRegularExpression(pattern: String(m.dropFirst(6))) else {
                    return .failure(ParseError(message: "bad title regex \(m.dropFirst(6))"))
                }
                title = re
            } else {
                return .failure(ParseError(message: "match with app:<name> or title:<regex>, not \(m)"))
            }
        }
        guard app != nil || title != nil else { return .failure(ParseError(message: "a rule needs app: or title:")) }
        return .success(Rule(effect: effect, app: app, title: title))
    }

    // MARK: Rules

    func rules(app: String, bundle: String, title: String) -> Applied {
        var a = Applied()
        for r in rules {
            if let want = r.app, want.caseInsensitiveCompare(app) != .orderedSame, want.caseInsensitiveCompare(bundle) != .orderedSame {
                continue
            }
            if let re = r.title, re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil { continue }
            switch r.effect {
            case .float: a.float = true
            case .tile: a.tile = true
            case .center: a.center = true
            case .size(let s): a.size = s; a.float = true
            case .workspace(let n, let silent): a.workspace = n; a.silent = silent
            }
        }
        return a
    }

    // MARK: Programs

    /// `exec-once`: once per login session — not again on Shoji restarts or config reloads.
    private func runExecOnce() {
        guard !execOnce.isEmpty else { return }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let dir = "/tmp/shoji-\(getuid())"
        mkdir(dir, 0o700)
        let marker = "\(dir)/exec-once-\(boot.tv_sec)"
        guard !FileManager.default.fileExists(atPath: marker) else { return }
        FileManager.default.createFile(atPath: marker, contents: nil)
        execOnce.forEach(Self.run)
    }

    /// Run a command line through the shell, detached, with Homebrew on the PATH.
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(NSHomeDirectory())/.docker/bin:" + path
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { ShojiLog.write("exec failed: \(command): \(error.localizedDescription)") }
    }

    // MARK: Watching

    /// Reload when the file is saved (editors usually replace the file, so watch its folder).
    private func watch() {
        let fd = open(Config.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fileMayHaveChanged() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func fileMayHaveChanged() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let m = (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
            guard m != self.lastModified else { return }
            ShojiLog.write("shoji.conf changed: reloading")
            self.load()
            self.exec.forEach(Self.run)
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Open shoji.conf in the default text editor.
    static func edit() {
        if !FileManager.default.fileExists(atPath: url.path) { UserConfig.shared.start() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]
        try? p.run()
    }

    static let defaultFile = """
    # Shoji config — in the style of hyprland.conf. Shoji reloads it every time you save.
    # The look (theme, gaps, modifier key, window options) stays in Settings (⌥,).
    #
    # $mod is the modifier from Settings (⌥ by default). Make your own variables: $name = value
    #
    # ── Keybindings ─────────────────────────────────────────────────────────────────────────
    # bind = MODS, KEY, dispatcher, argument
    #   MODS  $mod SHIFT CTRL ALT CMD, space-separated
    #   KEY   a–z, 0–9, Return, Tab, Space, Escape, Delete, Left/Right/Up/Down, F1–F12,
    #         comma, period, slash, backslash, semicolon, apostrophe, grave, minus, equal,
    #         bracketleft, bracketright
    #   Dispatchers: exec <command>, workspace <n|+1|-1>, movetoworkspace <n>,
    #     movetoworkspacesilent <n>, togglefloating, fullscreen, maximize, killactive, pin, centerwindow, togglesplit,
    #     movefocus <l|r|u|d>, swapwindow <l|r|u|d>, launcher, settings, stats, machines,
    #     containers, exit
    #   A bind on a key Shoji already uses replaces Shoji's own (⌥/ lists them all).
    #
    #bind = $mod, T, exec, open -na kitty --args --title htop htop
    #bind = $mod SHIFT, B, exec, open -na "Google Chrome"
    #
    # ── Window rules ────────────────────────────────────────────────────────────────────────
    # windowrule = EFFECT, app:<name or bundle id>, title:<regex>   (app:, title: or both)
    #   EFFECT: float, tile, center, size <w> <h>, workspace <n> [silent]
    #
    #windowrule = float, app:Calculator
    #windowrule = workspace 3 silent, app:Mail
    #windowrule = size 1100 700, app:kitty, title:^htop
    #
    # ── Workspaces ──────────────────────────────────────────────────────────────────────────
    # workspace = N, floating
    #
    #workspace = 9, floating
    #
    # ── Programs ────────────────────────────────────────────────────────────────────────────
    # exec-once = <command>   once per login (not on Shoji restarts)
    # exec = <command>        every time this file loads
    #
    #exec-once = open -ga Docker

    """
}

/// Runs a dispatcher by name — for `bind` lines in shoji.conf.
@MainActor
enum Dispatcher {
    static let names: Set<String> = [
        "exec", "workspace", "movetoworkspace", "movetoworkspacesilent", "togglefloating",
        "fullscreen", "maximize", "killactive", "pin", "centerwindow", "togglesplit", "movefocus", "swapwindow",
        "launcher", "settings", "stats", "machines", "containers", "exit",
    ]

    static func run(_ name: String, _ arg: String) {
        guard let wm = WindowManager.shared else { return }
        let a = arg.trimmingCharacters(in: .whitespaces)
        func direction() -> Direction? {
            switch a.lowercased().prefix(1) {
            case "l": return .left
            case "r": return .right
            case "u", "t": return .up
            case "d", "b": return .down
            default: return nil
            }
        }
        switch name {
        case "exec": UserConfig.run(a)
        case "workspace":
            if a == "+1" || a == "e+1" { wm.cycleWorkspaces(1) }
            else if a == "-1" || a == "e-1" { wm.cycleWorkspaces(-1) }
            else if let n = Int(a) { wm.switchTo(n) }
        case "movetoworkspace": if let n = Int(a) { wm.moveFocused(to: n, follow: true) }
        case "movetoworkspacesilent": if let n = Int(a) { wm.moveFocused(to: n, follow: false) }
        case "togglefloating": wm.toggleFloating()
        case "fullscreen": wm.toggleFullscreen(.full)
        case "maximize": wm.toggleFullscreen(.maximized)
        case "killactive": wm.closeFocused()
        case "pin": wm.togglePin()
        case "centerwindow": wm.centerFloating()
        case "togglesplit": wm.toggleSplit()
        case "movefocus": if let d = direction() { wm.focus(d) }
        case "swapwindow": if let d = direction() { wm.swap(d) }
        case "launcher": Launcher.shared.toggle()
        case "settings": SettingsWindow.toggle()
        case "stats": StatsWindow.toggle()
        case "machines": Programs.openMachines()
        case "containers": Programs.openContainers()
        case "exit": NSApp.terminate(nil)
        default: break
        }
    }
}

/// Hyprland-style: when shoji.conf has errors, a red banner at the top of the screen says which
/// lines (and the rest of the file still applies).
@MainActor
enum ConfigErrorBanner {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ errors: [String]) {
        hide()
        let c = Config.shared
        let text = "shoji.conf: " + errors.prefix(4).joined(separator: " · ") + (errors.count > 4 ? " · …" : "")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = c.monoUIFont(12, weight: .medium)
        label.textColor = c.crust
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let width = min(900, screen.frame.width - 80)
        label.preferredMaxLayoutWidth = width - 28
        let size = label.fittingSize
        let frame = CGRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - size.height - 28,
                           width: width, height: size.height + 20)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let box = NSView(frame: CGRect(origin: .zero, size: frame.size))
        box.wantsLayer = true
        box.layer?.backgroundColor = c.red.cgColor
        box.layer?.cornerRadius = 10
        label.frame = CGRect(x: 14, y: 10, width: width - 28, height: size.height)
        box.addSubview(label)
        p.contentView = box
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    static func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
