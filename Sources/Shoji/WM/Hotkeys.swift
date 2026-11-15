import AppKit
import Carbon.HIToolbox

/// A key Shoji binds, with how it's shown.
struct Key {
    let code: Int
    let label: String

    static let returnKey = Key(code: kVK_Return, label: "↩")
    static let tab = Key(code: kVK_Tab, label: "Tab")
    static let left = Key(code: kVK_LeftArrow, label: "←")
    static let right = Key(code: kVK_RightArrow, label: "→")
    static let up = Key(code: kVK_UpArrow, label: "↑")
    static let down = Key(code: kVK_DownArrow, label: "↓")
    static let grave = Key(code: kVK_ANSI_Grave, label: "`")
    static let comma = Key(code: kVK_ANSI_Comma, label: ",")
    static let slash = Key(code: kVK_ANSI_Slash, label: "/")
    static let leftBracket = Key(code: kVK_ANSI_LeftBracket, label: "[")
    static let rightBracket = Key(code: kVK_ANSI_RightBracket, label: "]")

    static func letter(_ c: Character) -> Key {
        let codes: [Character: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
            "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
            "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        ]
        return Key(code: codes[c]!, label: String(c))
    }

    static func digit(_ n: Int) -> Key {
        let codes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                     kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return Key(code: codes[n % 10], label: "\(n % 10)")
    }
}

/// One binding: Mod (+ extra modifiers) + key → action.
struct Binding {
    enum Extra { case none, shift, control, controlShift }
    let extra: Extra
    let key: Key
    let group: String
    let description: String
    let action: @MainActor () -> Void

    @MainActor var carbonModifiers: UInt32 {
        var m = Config.shared.modifierKey.carbon
        switch extra {
        case .none: break
        case .shift: m |= UInt32(shiftKey)
        case .control: m |= UInt32(controlKey)
        case .controlShift: m |= UInt32(controlKey | shiftKey)
        }
        return m
    }

    @MainActor var label: String {
        let extraLabel: String
        switch extra {
        case .none: extraLabel = ""
        case .shift: extraLabel = "⇧"
        case .control: extraLabel = "⌃"
        case .controlShift: extraLabel = "⌃⇧"
        }
        return Config.shared.modSymbol + extraLabel + key.label
    }
}

/// System-wide hotkeys via Carbon's RegisterEventHotKey: no extra permission, and the keys are
/// consumed (apps never see them).
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var failed: [String] = []

    func register(_ bindings: [Binding]) {
        installHandler()
        unregisterAll()
        failed = []
        for (i, b) in bindings.enumerated() {
            let id = EventHotKeyID(signature: OSType(0x53484F4A), id: UInt32(i + 1)) // 'SHOJ'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.key.code), b.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = b.action
            } else {
                failed.append(b.label) // taken by another app or the system
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Shoji's bindings — the Lucent Hyprland config's (ALT-mod variant), with Mod = Settings' modifier.
@MainActor
enum Bindings {
    static func all() -> [Binding] {
        guard let wm = WindowManager.shared else { return [] }
        var b: [Binding] = [
            Binding(extra: .none, key: .returnKey, group: "Apps", description: "Terminal") { Programs.open(.terminal) },
            Binding(extra: .shift, key: .returnKey, group: "Apps", description: "Floating terminal") { Programs.open(.terminal, floating: true) },
            Binding(extra: .shift, key: .letter("D"), group: "Apps", description: "App launcher") { Launcher.shared.toggle() },
            Binding(extra: .none, key: .letter("E"), group: "Apps", description: "File manager") { Programs.open(.files) },
            Binding(extra: .none, key: .letter("B"), group: "Apps", description: "Browser") { Programs.open(.browser) },
            Binding(extra: .none, key: .letter("N"), group: "Apps", description: "Editor") { Programs.open(.editor) },
            Binding(extra: .none, key: .comma, group: "Apps", description: "Shoji settings") { SettingsWindow.show() },
            Binding(extra: .none, key: .slash, group: "Apps", description: "Keybindings") { HelpPanel.toggle() },

            Binding(extra: .none, key: .letter("Q"), group: "Windows", description: "Close window") { wm.closeFocused() },
            Binding(extra: .none, key: .letter("J"), group: "Windows", description: "Flip split axis (dwindle)") { wm.toggleSplit() },
            Binding(extra: .none, key: .letter("F"), group: "Windows", description: "Fullscreen") { wm.toggleFullscreen(.full) },
            Binding(extra: .shift, key: .letter("F"), group: "Windows", description: "Maximise within gaps") { wm.toggleFullscreen(.maximized) },
            Binding(extra: .control, key: .letter("V"), group: "Windows", description: "Toggle floating") { wm.toggleFloating() },
            Binding(extra: .control, key: .letter("C"), group: "Windows", description: "Centre window") { wm.centerFloating() },
            Binding(extra: .shift, key: .letter("P"), group: "Windows", description: "Pin across workspaces") { wm.togglePin() },
            Binding(extra: .control, key: .tab, group: "Windows", description: "Cycle windows") { wm.cycleWindows() },
            Binding(extra: .none, key: .grave, group: "Windows", description: "Last window") { wm.focusPreviousWindow() },
            Binding(extra: .shift, key: .letter("M"), group: "Windows", description: "Exit Shoji") { NSApp.terminate(nil) },
        ]
        let dirs: [(Key, Direction, String)] = [(.left, .left, "left"), (.right, .right, "right"), (.up, .up, "up"), (.down, .down, "down")]
        for (key, d, name) in dirs {
            b.append(Binding(extra: .none, key: key, group: "Focus & move", description: "Focus \(name)") { wm.focus(d) })
            b.append(Binding(extra: .shift, key: key, group: "Focus & move", description: "Move window \(name)") { wm.swap(d) })
            b.append(Binding(extra: .control, key: key, group: "Focus & move", description: "Resize \(name)") { wm.resize(d) })
        }
        // Vim keys, as in Lucent (J is the split flip, so there's no Mod+J focus).
        b.append(Binding(extra: .none, key: .letter("H"), group: "Focus & move", description: "Focus left") { wm.focus(.left) })
        b.append(Binding(extra: .none, key: .letter("L"), group: "Focus & move", description: "Focus right") { wm.focus(.right) })
        b.append(Binding(extra: .none, key: .letter("K"), group: "Focus & move", description: "Focus up") { wm.focus(.up) })
        b.append(Binding(extra: .shift, key: .letter("H"), group: "Focus & move", description: "Move window left") { wm.swap(.left) })
        b.append(Binding(extra: .shift, key: .letter("L"), group: "Focus & move", description: "Move window right") { wm.swap(.right) })
        b.append(Binding(extra: .shift, key: .letter("K"), group: "Focus & move", description: "Move window up") { wm.swap(.up) })
        b.append(Binding(extra: .shift, key: .letter("J"), group: "Focus & move", description: "Move window down") { wm.swap(.down) })

        for i in 1...Config.shared.workspaceCount {
            b.append(Binding(extra: .none, key: .digit(i), group: "Workspaces", description: "Workspace \(i)") { wm.switchTo(i) })
            b.append(Binding(extra: .shift, key: .digit(i), group: "Workspaces", description: "Window to workspace \(i)") {
                wm.moveFocused(to: i, follow: true)
            })
            if i <= 5 {
                b.append(Binding(extra: .control, key: .digit(i), group: "Workspaces", description: "Window to workspace \(i) (silent)") {
                    wm.moveFocused(to: i, follow: false)
                })
            }
        }
        b.append(Binding(extra: .none, key: .tab, group: "Workspaces", description: "Next workspace") { wm.cycleWorkspaces(1) })
        b.append(Binding(extra: .shift, key: .tab, group: "Workspaces", description: "Previous workspace") { wm.cycleWorkspaces(-1) })
        b.append(Binding(extra: .none, key: .rightBracket, group: "Workspaces", description: "Next workspace") { wm.cycleWorkspaces(1) })
        b.append(Binding(extra: .none, key: .leftBracket, group: "Workspaces", description: "Previous workspace") { wm.cycleWorkspaces(-1) })
        return b
    }
}
