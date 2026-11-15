import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wm: WindowManager?
    private var workspaceMenu: WorkspaceMenu?
    private var permissionWindow: NSWindow?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastModifier = Config.shared.modifierKey

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.shared.load()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            Preview.render(to: args[i + 1]) // offscreen render of the bar and dock; touches nothing
            NSApp.terminate(nil)
            return
        }
        // Debug: write kitty's theme.conf for a theme (use CFFIXED_USER_HOME to aim it elsewhere).
        if let i = args.firstIndex(of: "--write-kitty"), i + 1 < args.count, let t = ThemeLibrary.theme(args[i + 1]) {
            ThemeSync.writeKitty(t)
            ThemeSync.writeKittySettings()
            NSApp.terminate(nil)
            return
        }
        // One Shoji at a time.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { NSApp.terminate(nil); return }

        if AX.isTrusted { start() } else { askForPermission() }
    }

    /// Shoji moves other apps' windows, which needs the Accessibility permission.
    private func askForPermission() {
        AX.requestTrust()
        let c = Config.shared
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 210), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Shoji"
        w.isReleasedWhenClosed = false
        let root = FlippedView()
        w.contentView = root
        let title = NSTextField(labelWithString: "Allow Shoji to arrange your windows")
        title.font = c.uiFont(16, weight: .semibold)
        title.frame = CGRect(x: 24, y: 22, width: 412, height: 22)
        let body = NSTextField(wrappingLabelWithString: "Shoji tiles windows through the Accessibility API. Turn on Shoji in "
            + "System Settings → Privacy & Security → Accessibility. Shoji starts by itself as soon as it's allowed.")
        body.font = c.uiFont(12.5, weight: .regular)
        body.frame = CGRect(x: 24, y: 54, width: 412, height: 70)
        let open = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openPrivacy))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.sizeToFit()
        open.frame.origin = CGPoint(x: 436 - open.frame.width, y: 150)
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.sizeToFit()
        quit.frame.origin = CGPoint(x: open.frame.minX - 8 - quit.frame.width, y: 150)
        [title, body, open, quit].forEach(root.addSubview)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        permissionWindow = w
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AX.isTrusted, let self else { return }
                self.permissionTimer?.invalidate()
                self.permissionWindow?.close()
                self.start()
            }
        }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func start() {
        // Earlier versions auto-hid the menu bar and Dock; put back anything they left changed.
        SystemChrome.restore()
        let wm = WindowManager()
        self.wm = wm
        wm.start()
        workspaceMenu = WorkspaceMenu()
        wm.onChange = { [weak self] in self?.workspaceMenu?.refresh() }
        Hotkeys.shared.register(Bindings.all())
                NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Config.shared.modifierKey != self.lastModifier {
                    self.lastModifier = Config.shared.modifierKey
                    Hotkeys.shared.register(Bindings.all())
                }
                self.workspaceMenu?.refresh()
            }
        }
        // `kill` / logout: quit properly, so parked windows come back.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Hotkeys.shared.unregisterAll()
        wm?.restoreAllWindows()
    }
}
