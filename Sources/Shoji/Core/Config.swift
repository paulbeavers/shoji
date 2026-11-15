import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let configDidChange = Notification.Name("ShojiConfigDidChange")
}

extension NSColor {
    /// Create a color from a 0xRRGGBB value.
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// "#RRGGBBAA" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hexString: String) {
        var h = hexString.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let rgba = h.count == 6 ? (v << 8) | 0xFF : v
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}

/// Shoji's "Super": the modifier for every binding. Option by default (the Lucent Hyprland
/// config's ALT mode); ⌘ would collide with every app's own shortcuts.
enum ModifierKey: String, CaseIterable {
    case option, controlOption, command

    var carbon: UInt32 {
        switch self {
        case .option: return UInt32(optionKey)
        case .controlOption: return UInt32(optionKey | controlKey)
        case .command: return UInt32(cmdKey)
        }
    }
    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .controlOption: return "⌃⌥"
        case .command: return "⌘"
        }
    }
    var title: String {
        switch self {
        case .option: return "Option (⌥)"
        case .controlOption: return "Control-Option (⌃⌥)"
        case .command: return "Command (⌘)"
        }
    }
}

/// The user-editable part of `Config`, as stored in ~/.config/shoji/settings.json. Every field is
/// optional so older or hand-edited files still load.
struct SettingsFile: Codable {
    var theme: String?
    var gapsIn: Double?
    var gapsOut: Double?
    var borderSize: Double?
    var rounding: Double?
    var activeBorderStart: String?
    var activeBorderEnd: String?
    var inactiveBorder: String?
    var focusFollowsMouse: Bool?
    var focusOnActivate: Bool?
    var modifierKey: String?
    var floatingWorkspaces: [Int]?
    var showDock: Bool?
    var dockIconSize: Double?
    var dockPinned: [String]?
    var hideMenuBar: Bool?
    var hideSystemDock: Bool?
    var terminalApp: String?
    var browserApp: String?
    var editorApp: String?
    var floatApps: [String]?
    var blur: Bool?
    var themeSetsAppearance: Bool?
    var themeSetsWallpaper: Bool?
    var themeSetsKitty: Bool?
    var themeSetsAccent: Bool?
}

/// Runtime configuration, modelled on hyprland.conf's `general` and `decoration` sections.
/// The Settings window edits it, then calls `notifyChanged()` and `save()`.
@MainActor
final class Config {
    static let shared = Config()

    nonisolated static let appName = "Shoji"

    /// ~/.config/shoji — settings, themes, saved system settings.
    nonisolated static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["SHOJI_CONFIG_DIR"] { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/shoji")
    }

    // general (hyprland.conf: gaps_in 5, gaps_out 10, border_size 2 — Lucent's values)
    var gapsIn: CGFloat = 5
    var gapsOut: CGFloat = 10
    /// Corner radius of the bar's pills, the dock and the launcher.
    var rounding: CGFloat = 12
    /// The theme's highlight gradient (mauve → blue), used for the active workspace pill.
    var activeBorder: [NSColor] = [NSColor(hex: 0xCBA6F7), NSColor(hex: 0x89B4FA)]
    var inactiveBorder = NSColor(hex: 0x313244)
    var focusFollowsMouse = false
    /// When an app activates a window on another workspace (dock click, ⌘Tab), go there.
    var focusOnActivate = true

    // What picking a theme also changes (see ThemeSync).
    var themeSetsAppearance = true
    var themeSetsWallpaper = true
    var themeSetsKitty = true
    var themeSetsAccent = true
    var modifierKey: ModifierKey = .option
    var modSymbol: String { modifierKey.symbol }
    /// Render a binding written with "⌥" for the configured modifier.
    func shortcut(_ s: String) -> String { s.replacingOccurrences(of: "⌥", with: modSymbol) }

    // workspaces
    var workspaceCount = 10
    var minVisibleWorkspaces = 5
    var floatingWorkspaces: Set<Int> = []

    // bar & dock

    // programs (bundle ids; empty = automatic)
    var terminalApp = ""
    var browserApp = ""
    var editorApp = ""
    /// Apps whose windows always float (fixed-size utilities).
    var floatApps: Set<String> = ["com.apple.systempreferences", "com.apple.calculator", "com.apple.archiveutility",
                                  "com.apple.Passwords", "com.apple.ScreenSharing", "com.apple.FaceTime"]

    // MARK: Theme

    var themeID = "catppuccin-mocha"
    var palette = Palette.mocha
    var isLight: Bool { palette.isLight }
    var appearance: NSAppearance { NSAppearance(named: isLight ? .aqua : .darkAqua)! }

    var base: NSColor { palette.base }
    var mantle: NSColor { palette.mantle }
    var crust: NSColor { palette.crust }
    var surface0: NSColor { palette.surface0 }
    var surface1: NSColor { palette.surface1 }
    var overlay0: NSColor { palette.overlay }
    var text: NSColor { palette.text }
    var subtext: NSColor { palette.subtext }
    var accent: NSColor { palette.mauve }
    var accent2: NSColor { palette.green }
    var red: NSColor { palette.red }
    var yellow: NSColor { palette.yellow }

    /// Switch to a theme. With `fully`, also take its borders (focused = mauve→blue at 45°,
    /// unfocused = `border` or surface0, as in Lucent's theme.lua).
    func applyTheme(_ t: LucentTheme, fully: Bool) {
        themeID = t.id
        palette = t.palette
        guard fully else { return }
        activeBorder = [t.palette.mauve, t.palette.blue]
        inactiveBorder = t.border ?? t.palette.surface0
    }

    func selectTheme(_ id: String) {
        guard let t = ThemeLibrary.theme(id) else { return }
        applyTheme(t, fully: true)
        notifyChanged()
        save()
        ThemeSync.apply(t) // appearance, wallpaper, kitty, accent colour
    }

    func uiFont(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    func monoUIFont(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: .configDidChange, object: self)
    }

    // MARK: Persistence

    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func snapshot() -> SettingsFile {
        SettingsFile(
            theme: themeID, gapsIn: gapsIn, gapsOut: gapsOut, borderSize: nil, rounding: rounding,
            activeBorderStart: activeBorder.first?.hexString, activeBorderEnd: activeBorder.last?.hexString,
            inactiveBorder: inactiveBorder.hexString, focusFollowsMouse: focusFollowsMouse,
            focusOnActivate: focusOnActivate, modifierKey: modifierKey.rawValue,
            floatingWorkspaces: floatingWorkspaces.sorted(), showDock: nil, dockIconSize: nil,
            dockPinned: nil, hideMenuBar: nil, hideSystemDock: nil,
            terminalApp: terminalApp, browserApp: browserApp, editorApp: editorApp,
            floatApps: floatApps.sorted(), blur: nil,
            themeSetsAppearance: themeSetsAppearance, themeSetsWallpaper: themeSetsWallpaper,
            themeSetsKitty: themeSetsKitty, themeSetsAccent: themeSetsAccent)
    }

    func apply(_ f: SettingsFile) {
        if let id = f.theme, let t = ThemeLibrary.theme(id) { applyTheme(t, fully: false) }
        if let v = f.gapsIn { gapsIn = CGFloat(v) }
        if let v = f.gapsOut { gapsOut = CGFloat(v) }
        if let v = f.rounding { rounding = CGFloat(v) }
        if let a = f.activeBorderStart.flatMap(NSColor.init(hexString:)),
           let b = f.activeBorderEnd.flatMap(NSColor.init(hexString:)) { activeBorder = [a, b] }
        if let v = f.inactiveBorder.flatMap(NSColor.init(hexString:)) { inactiveBorder = v }
        if let v = f.focusFollowsMouse { focusFollowsMouse = v }
        if let v = f.focusOnActivate { focusOnActivate = v }
        if let v = f.modifierKey.flatMap(ModifierKey.init(rawValue:)) { modifierKey = v }
        if let v = f.floatingWorkspaces { floatingWorkspaces = Set(v) }
        if let v = f.terminalApp { terminalApp = v }
        if let v = f.browserApp { browserApp = v }
        if let v = f.editorApp { editorApp = v }
        if let v = f.floatApps { floatApps = Set(v) }
        if let v = f.themeSetsAppearance { themeSetsAppearance = v }
        if let v = f.themeSetsWallpaper { themeSetsWallpaper = v }
        if let v = f.themeSetsKitty { themeSetsKitty = v }
        if let v = f.themeSetsAccent { themeSetsAccent = v }
    }

    /// Load saved settings; on first run take Lucent's default theme, borders and all.
    func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let f = try? JSONDecoder().decode(SettingsFile.self, from: data) else {
            if let t = ThemeLibrary.theme(ThemeLibrary.defaultID) { applyTheme(t, fully: true) }
            return
        }
        apply(f)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot()) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    func resetToDefaults() {
        let d = Config()
        if let t = ThemeLibrary.theme(ThemeLibrary.defaultID) { d.applyTheme(t, fully: true) }
        apply(d.snapshot())
        notifyChanged()
        save()
    }
}
