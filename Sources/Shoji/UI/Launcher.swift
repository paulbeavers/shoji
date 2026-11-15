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
    private let box = ScrollBox()
    private let field = NSTextField()
    /// The visible rows: always `visibleRows` views, showing `matches[top ..< top + visibleRows]`.
    private var rows: [LauncherRow] = []
    private let scrollBar = NSView()
    private var apps: [(name: String, url: URL)] = []
    private var matches: [(name: String, url: URL)] = []
    /// Index into `matches` (not into the visible rows).
    private var selected = 0
    /// The first match shown.
    private var top = 0
    private let visibleRows = 8
    private var icons: [URL: NSImage] = [:]
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
        for i in 0..<visibleRows {
            let row = LauncherRow()
            row.onClick = { [weak self] in guard let self else { return }; self.launch(self.top + i) }
            row.isHidden = true
            box.addSubview(row)
            rows.append(row)
        }
        scrollBar.wantsLayer = true
        scrollBar.layer?.cornerRadius = 2
        box.addSubview(scrollBar)
        // Mouse wheel / trackpad: scroll the list a row per notch (the selection stays in view).
        box.onScroll = { [weak self] rows in self?.scroll(by: rows) }
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
            // Only real matches: the name starts with the text, or one of its words does (words
            // split at spaces, hyphens and dots, and at capitals inside a name: "memos" finds
            // VoiceMemos). Name matches first. Text in the middle of a word doesn't count ("sa"
            // listed Messages under Safari).
            func score(_ name: String) -> Int? {
                if name.lowercased().hasPrefix(q) { return 0 }
                return Self.words(of: name).contains { $0.hasPrefix(q) } ? 1 : nil
            }
            // Name matches before word matches; alphabetical within each.
            var scored: [(app: (name: String, url: URL), score: Int)] = []
            for a in apps { if let sc = score(a.name) { scored.append((a, sc)) } }
            scored.sort { x, y in
                if x.score != y.score { return x.score < y.score }
                return x.app.name.localizedCaseInsensitiveCompare(y.app.name) == .orderedAscending
            }
            matches = scored.map { $0.app }
        }
        selected = 0
        top = 0
        showRows()
        layout()
    }

    /// "Visual Studio Code" → visual, studio, code; "VoiceMemos" → voicememos, voice, memos.
    static func words(of name: String) -> [String] {
        var words: [String] = []
        for part in name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" }) {
            words.append(part.lowercased())
            var current = ""
            var previous: Character?
            for ch in part {
                if ch.isUppercase, let p = previous, p.isLowercase, !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(ch)
                previous = ch
            }
            if current.count < part.count { words.append(current.lowercased()) }
        }
        return words
    }

    private func icon(_ url: URL) -> NSImage {
        if let i = icons[url] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = i
        return i
    }

    /// Fill the row views from `matches[top...]` and mark the selection.
    private func showRows() {
        for (i, row) in rows.enumerated() {
            let m = top + i
            row.isHidden = m >= matches.count
            guard m < matches.count else { continue }
            row.set(name: matches[m].name, icon: icon(matches[m].url))
            row.isSelected = m == selected
        }
        updateScrollBar()
    }

    /// A thin bar on the right showing which part of a long list is in view.
    private func updateScrollBar() {
        let count = matches.count
        scrollBar.isHidden = count <= visibleRows
        guard count > visibleRows, let first = rows.first?.frame, let last = rows.last?.frame else { return }
        let trackTop = first.maxY, trackBottom = last.minY, track = trackTop - trackBottom
        let height = max(18, track * CGFloat(visibleRows) / CGFloat(count))
        let y = trackTop - height - (track - height) * CGFloat(top) / CGFloat(count - visibleRows)
        scrollBar.frame = CGRect(x: box.bounds.width - 9, y: y, width: 4, height: height)
    }

    /// Scroll the window of rows by `n`, keeping the selection inside it.
    private func scroll(by n: Int) {
        let maxTop = max(0, matches.count - visibleRows)
        let newTop = min(maxTop, max(0, top + n))
        guard newTop != top else { return }
        top = newTop
        selected = min(max(selected, top), min(matches.count, top + visibleRows) - 1)
        showRows()
    }

    private func applyColors() {
        box.layer?.backgroundColor = c.base.withAlphaComponent(0.97).cgColor
        box.layer?.borderColor = c.accent.cgColor
        box.layer?.cornerRadius = c.rounding
        scrollBar.layer?.backgroundColor = c.overlay0.withAlphaComponent(0.7).cgColor
        rows.forEach { $0.refreshColors() }
        field.textColor = c.text
        panel.appearance = c.appearance
    }

    private func layout() {
        let w: CGFloat = 560
        let shown = min(visibleRows, matches.count)
        let h = 64 + CGFloat(shown) * 40 + 10
        box.frame = CGRect(x: 0, y: 420 - h, width: w, height: h)
        field.frame = CGRect(x: 20, y: h - 46, width: w - 40, height: 26)
        for (i, r) in rows.enumerated() {
            // Leave room for the scroll bar when the list is longer than the window.
            r.frame = CGRect(x: 10, y: h - 64 - CGFloat(i + 1) * 40, width: w - (matches.count > visibleRows ? 34 : 20), height: 38)
        }
        updateScrollBar()
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
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(visibleRows, wrap: false)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-visibleRows, wrap: false)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            move(-matches.count, wrap: false)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)):
            move(matches.count, wrap: false)
        case #selector(NSResponder.insertNewline(_:)): launch(selected)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    /// Move the selection through all matches (arrows wrap around; page/home/end stop at the
    /// ends), scrolling the rows to keep it in view.
    private func move(_ d: Int, wrap: Bool = true) {
        let n = matches.count
        guard n > 0 else { return }
        selected = wrap ? ((selected + d) % n + n) % n : min(n - 1, max(0, selected + d))
        if selected < top { top = selected }
        if selected >= top + visibleRows { top = selected - visibleRows + 1 }
        showRows()
    }
}

/// The launcher's box: passes mouse-wheel / trackpad scrolling on as whole rows.
final class ScrollBox: NSView {
    var onScroll: ((Int) -> Void)?
    private var pending: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // Trackpads send many small, precise deltas; a mouse wheel sends whole lines.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 30 : event.scrollingDeltaY
        pending -= delta // content follows the fingers (natural scrolling is already in the sign)
        let rows = Int(pending.rounded(.towardZero))
        guard rows != 0 else { return }
        pending -= CGFloat(rows)
        onScroll?(rows)
    }
}

final class LauncherRow: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { refreshColors() } }
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = Config.shared.uiFont(14, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(label)
        refreshColors()
    }

    func set(name: String, icon: NSImage) {
        guard label.stringValue != name || iconView.image !== icon else { return }
        label.stringValue = name
        iconView.image = icon
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        iconView.frame = CGRect(x: 10, y: (bounds.height - 26) / 2, width: 26, height: 26)
        label.sizeToFit()
        label.frame = CGRect(x: 46, y: (bounds.height - label.frame.height) / 2,
                             width: min(label.frame.width, bounds.width - 56), height: label.frame.height)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func refreshColors() {
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
