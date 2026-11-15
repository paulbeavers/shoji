import AppKit
import Carbon.HIToolbox

/// The apps Mod+Return / E / B / N open (Lucent's programs.lua), and launching in general.
@MainActor
enum Programs {
    enum Role { case terminal, browser, editor, files }

    static let kitty = "net.kovidgoyal.kitty"

    /// Candidates offered in Settings (kitty is the default).
    static let terminals = ["com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
                            "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
    static let editors = ["dev.zed.Zed", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
                          "com.panic.Nova", "com.apple.TextEdit"]

    static func bundleID(for role: Role) -> String? {
        let c = Config.shared
        switch role {
        case .terminal: return c.terminalApp.isEmpty ? kitty : c.terminalApp // kitty is assumed installed
        case .editor: return c.editorApp.isEmpty ? editors.first(where: isInstalled) : c.editorApp
        case .files: return "com.apple.finder"
        case .browser:
            if !c.browserApp.isEmpty { return c.browserApp }
            let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            return url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "com.apple.Safari"
        }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func open(_ role: Role, floating: Bool = false) {
        guard let id = bundleID(for: role) else { NSSound.beep(); return }
        if floating { WindowManager.shared?.floatNextWindow(of: id) }
        newWindow(id)
    }

    /// Open a new window of an app: launch it, or — when it's running — ask it for one (⌘N), the
    /// way Hyprland's exec opens a fresh terminal every time.
    static func newWindow(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            WindowManager.shared?.holdWorkspace() // the new window opens here, not where the app's others are
            AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postCommandN(to: app.processIdentifier)
            }
        } else {
            launch(bundleID)
        }
    }

    /// Shoji Machines, the VM companion app (its own repo, ../shoji-machines; its build registers
    /// it with Launch Services).
    static let machinesBundleID = "dev.shoji.Machines"

    /// Shoji Containers, the Docker companion app (its own repo, ../shoji-containers).
    static let containersBundleID = "dev.shoji.Containers"

    /// Mod+M: open Shoji Machines, or bring its window forward.
    static func openMachines() { openCompanion(machinesBundleID, name: "Shoji Machines", repo: "shoji-machines") }

    /// Mod+O: open Shoji Containers, or bring its window forward.
    static func openContainers() { openCompanion(containersBundleID, name: "Shoji Containers", repo: "shoji-containers") }

    /// A companion app, found through Launch Services (each one's build registers it).
    private static func openCompanion(_ bundleID: String, name: String, repo: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            ShojiLog.write("\(name) isn't installed (build ../\(repo))")
            NSSound.beep()
            return
        }
        launch(url: url)
    }

    static func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { NSSound.beep(); return }
        launch(url: url)
    }

    static func launch(url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func postCommandN(to pid: pid_t) { postCommandKey(kVK_ANSI_N, to: pid) }

    /// ⌘ + key, sent straight to one app.
    static func postCommandKey(_ key: Int, to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(pid)
        }
    }
}
