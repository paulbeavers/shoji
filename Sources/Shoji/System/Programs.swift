import AppKit
import Carbon.HIToolbox

/// The apps Mod+Return / E / B / N open (Lucent's programs.lua), and launching in general.
@MainActor
enum Programs {
    enum Role { case terminal, browser, editor, files }

    /// Candidates in order of preference when Settings says "Automatic".
    static let terminals = ["com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
                            "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
    static let editors = ["dev.zed.Zed", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
                          "com.panic.Nova", "com.apple.TextEdit"]

    static func bundleID(for role: Role) -> String? {
        let c = Config.shared
        switch role {
        case .terminal: return c.terminalApp.isEmpty ? terminals.first(where: isInstalled) : c.terminalApp
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
            AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                postCommandN(to: app.processIdentifier)
            }
        } else {
            launch(bundleID)
        }
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

    private static func postCommandN(to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(pid)
        }
    }
}
