import AppKit

// Shoji restores its own state; macOS's "reopen windows?" prompt after a crash would only get
// in the way of a window manager.
UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")

if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { AppIcon.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon or menu bar of its own
    app.run()
}
