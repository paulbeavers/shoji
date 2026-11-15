import AppKit

/// A panel that can take the keyboard (the launcher's search field). Shoji is an accessory app,
/// so showing one activates Shoji until it closes.
class KeyPanel: NSPanel {
    /// Closing: `refocus` = give the keyboard back to the managed window (Esc, toggling it off);
    /// false when the user clicked elsewhere — that click already chose what gets focus.
    var onClose: ((_ refocus: Bool) -> Void)?
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?(true) }
    override func resignKey() {
        super.resignKey()
        onClose?(false) // clicking elsewhere closes it, like wofi
    }
}

/// Mod+Shift+D: a wofi-style app launcher over the screen centre.
@MainActor
final class Launcher: NSObject, NSTextFieldDelegate {
    static let shared = Launcher()

    private let panel = KeyPanel(size: CGSize(width: 560, height: 420))
    private let box = NSView()
    private let field = NSTextField()
    private var rows: [LauncherRow] = []
    private var apps: [(name: String, url: URL)] = []
    private var matches: [(name: String, url: URL)] = []
    private var selected = 0
    private var c: Config { .shared }

    override init() {
        super.init()
        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 2
        root.addSubview(box)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = c.uiFont(17, weight: .regular)
        field.placeholderString = "Run an app…"
        field.delegate = self
        box.addSubview(field)
        panel.onClose = { [weak self] refocus in self?.hide(refocus: refocus) }
    }

    var isShown: Bool { panel.isVisible }

    func toggle() { isShown ? hide() : show() }

    func show() {
        apps = Self.installedApps()
        field.stringValue = ""
        filter()
        applyColors()
        let s = (NSScreen.screens.first ?? NSScreen.main!).frame
        panel.setFrame(CGRect(x: s.midX - 280, y: s.midY - 120, width: 560, height: 420), display: true)
        layout()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// `refocus: false` when something else takes focus anyway (an app just launched, a click).
    func hide(refocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if refocus { WindowManager.shared?.refocusAfterPanel() }
    }

    /// Apps in the standard folders (one level deep, plus Utilities).
    static func installedApps() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    home.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var list: [(String, URL)] = []
        for d in dirs {
            for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                if seen.insert(name).inserted { list.append((name, url)) }
            }
        }
        return list.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func filter() {
        let q = field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            matches = apps
        } else {
            // Prefix matches first, then word starts, then anywhere.
            func score(_ name: String) -> Int? {
                let n = name.lowercased()
                if n.hasPrefix(q) { return 0 }
                if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
                if n.contains(q) { return 2 }
                return nil
            }
            matches = apps.compactMap { a in score(a.name).map { (a, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        selected = 0
        rebuildRows()
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.prefix(8).enumerated().map { i, app in
            let row = LauncherRow(name: app.name, icon: NSWorkspace.shared.icon(forFile: app.url.path))
            row.isSelected = i == selected
            row.onClick = { [weak self] in self?.launch(i) }
            box.addSubview(row)
            return row
        }
        layout()
    }

    private func applyColors() {
        box.layer?.backgroundColor = c.base.withAlphaComponent(0.97).cgColor
        box.layer?.borderColor = c.accent.cgColor
        box.layer?.cornerRadius = c.rounding
        field.textColor = c.text
        panel.appearance = c.appearance
    }

    private func layout() {
        let w: CGFloat = 560
        let h = 64 + CGFloat(rows.count) * 40 + 10
        box.frame = CGRect(x: 0, y: 420 - h, width: w, height: h)
        field.frame = CGRect(x: 20, y: h - 46, width: w - 40, height: 26)
        for (i, r) in rows.enumerated() {
            r.frame = CGRect(x: 10, y: h - 64 - CGFloat(i + 1) * 40, width: w - 20, height: 38)
        }
    }

    private func launch(_ i: Int) {
        guard i < matches.count else { return }
        hide(refocus: false)
        Programs.launch(url: matches[i].url)
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): launch(selected)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    private func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + d + rows.count) % rows.count
        for (i, r) in rows.enumerated() { r.isSelected = i == selected }
    }
}

final class LauncherRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateColors() } }
    private let iconView = NSImageView()
    private let label: NSTextField

    init(name: String, icon: NSImage) {
        label = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        iconView.image = icon
        label.font = Config.shared.uiFont(14, weight: .medium)
        addSubview(iconView)
        addSubview(label)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        iconView.frame = CGRect(x: 10, y: (bounds.height - 26) / 2, width: 26, height: 26)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 46, y: (bounds.height - label.frame.height) / 2)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    private func updateColors() {
        let c = Config.shared
        layer?.backgroundColor = isSelected ? c.surface0.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? c.text : c.subtext
    }
}

/// Mod+/: every binding, grouped.
@MainActor
enum HelpPanel {
    private static var panel: KeyPanel?

    static func toggle() {
        if let p = panel, p.isVisible { close(p, refocus: true); return }
        let c = Config.shared
        let bindings = Bindings.all()
        let groups = ["Apps", "Windows", "Focus & move", "Workspaces"]
            + (bindings.contains { $0.group == "Config" } ? ["Config"] : []) // shoji.conf binds
        // Workspace lines collapse to ranges so the sheet stays short.
        var lines: [[(String, String)]] = groups.map { g in
            bindings.filter { $0.group == g && !$0.description.hasPrefix("Workspace ") && !$0.description.hasPrefix("Window to workspace") }
                .map { ($0.label, $0.description) }
        }
        lines[3].insert(("\(c.modSymbol)⌃1…5", "Window to workspace (silent)"), at: 0)
        lines[3].insert(("\(c.modSymbol)⇧1…0", "Window to workspace"), at: 0)
        lines[3].insert(("\(c.modSymbol)1…0", "Go to workspace"), at: 0)

        let colW: CGFloat = 300, lineH: CGFloat = 21
        let colHeights = lines.map { CGFloat($0.count + 2) * lineH }
        let h = max(colHeights.prefix(2).reduce(0, +), colHeights.dropFirst(2).reduce(0, +)) + 60
        let w = colW * 2 + 60
        let p = KeyPanel(size: CGSize(width: w, height: h))
        p.onClose = { [weak p] refocus in if let p { close(p, refocus: refocus) } }
        let root = FlippedView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = c.base.withAlphaComponent(0.97).cgColor
        root.layer?.cornerRadius = c.rounding
        root.layer?.borderWidth = 2
        root.layer?.borderColor = c.accent.cgColor
        p.contentView = root
        p.appearance = c.appearance
        var y: [CGFloat] = [24, 24]
        for (gi, g) in groups.enumerated() {
            let col = gi < 2 ? 0 : 1
            let x = 30 + CGFloat(col) * colW
            let title = NSTextField(labelWithString: g)
            title.font = c.uiFont(13, weight: .semibold)
            title.textColor = c.accent
            title.frame = CGRect(x: x, y: y[col], width: colW, height: 18)
            root.addSubview(title)
            y[col] += lineH + 4
            for (key, desc) in lines[gi] {
                let k = NSTextField(labelWithString: key)
                k.font = c.monoUIFont(11.5, weight: .semibold)
                k.textColor = c.text
                k.frame = CGRect(x: x, y: y[col], width: 86, height: 18)
                let d = NSTextField(labelWithString: desc)
                d.font = c.uiFont(12, weight: .regular)
                d.textColor = c.subtext
                d.frame = CGRect(x: x + 90, y: y[col], width: colW - 100, height: 18)
                root.addSubview(k)
                root.addSubview(d)
                y[col] += lineH
            }
            y[col] += lineH
        }
        let s = (NSScreen.screens.first ?? NSScreen.main!).frame
        p.setFrame(CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h), display: true)
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private static func close(_ p: KeyPanel, refocus: Bool) {
        guard p.isVisible else { return }
        p.orderOut(nil)
        if refocus { WindowManager.shared?.refocusAfterPanel() }
    }
}

final class FlippedView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
