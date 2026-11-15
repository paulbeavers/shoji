import AppKit

/// Early Shoji versions auto-hid the macOS menu bar and Dock (saving the user's values first).
/// Shoji now uses both as they are; at launch this puts back anything those versions left changed.
@MainActor
enum SystemChrome {
    private struct Saved: Codable {
        var menuBarHidden: Bool?   // _HIHideMenuBar (nil = key absent)
        var menuBarInFullscreen: Bool?
        var dockAutohide: Bool?
        var dockDelay: Double?
    }

    private static var backupURL: URL { Config.directory.appendingPathComponent("system-settings-backup.json") }
    private static let global = kCFPreferencesAnyApplication
    private static let dock = "com.apple.dock" as CFString

    static func restore() {
        guard let data = try? Data(contentsOf: backupURL), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        CFPreferencesSetAppValue("_HIHideMenuBar" as CFString, s.menuBarHidden.map { $0 as CFBoolean } as CFPropertyList?, global)
        CFPreferencesSetAppValue("AppleMenuBarVisibleInFullscreen" as CFString,
                                 s.menuBarInFullscreen.map { $0 as CFBoolean } as CFPropertyList?, global)
        CFPreferencesAppSynchronize(global)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil,
            deliverImmediately: true)
        let autohide = (CFPreferencesCopyAppValue("autohide" as CFString, dock) as? NSNumber)?.boolValue
        let delay = (CFPreferencesCopyAppValue("autohide-delay" as CFString, dock) as? NSNumber)?.doubleValue
        if autohide != s.dockAutohide || delay != s.dockDelay {
            CFPreferencesSetAppValue("autohide" as CFString, s.dockAutohide.map { $0 as CFBoolean } as CFPropertyList?, dock)
            CFPreferencesSetAppValue("autohide-delay" as CFString, s.dockDelay.map { $0 as NSNumber } as CFPropertyList?, dock)
            CFPreferencesAppSynchronize(dock)
            // The Dock reads its settings at startup (what `killall Dock` does).
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
                kill(app.processIdentifier, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(at: backupURL)
    }
}
