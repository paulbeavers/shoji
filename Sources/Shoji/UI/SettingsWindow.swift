import AppKit
import UniformTypeIdentifiers

/// Shoji settings (Mod+,): edits `Config.shared` live and saves to ~/.config/shoji/settings.json.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var current: SettingsWindow?

    /// Open Settings as a tile in the current workspace (or go to it if it's already open).
    static func show() {
        let wm = WindowManager.shared
        if let s = current, s.window.isVisible {
            wm?.tileOwnWindow(s.window) // already tiled: focuses it (switching workspace if needed)
            return
        }
        let s = current ?? SettingsWindow()
        current = s
        NSApp.activate(ignoringOtherApps: true)
        s.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { wm?.tileOwnWindow(s.window) }
    }

    /// `--preview-settings out.png`: render the window's contents offscreen.
    static func renderPreview(to path: String) {
        let s = SettingsWindow()
        s.view.frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        s.layout()
        s.view.layoutSubtreeIfNeeded()
        let rep = s.view.bitmapImageRepForCachingDisplay(in: s.view.bounds)!
        s.view.cacheDisplay(in: s.view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Mod+,: open Settings, or close it if it's the focused window.
    static func toggle() {
        if let s = current, s.window.isVisible, WindowManager.shared?.isFocused(s.window) ?? s.window.isKeyWindow {
            s.window.performClose(nil)
        } else {
            show()
        }
    }

    let view: NSView
    let window: ShojiWindow
    /// Always a way to close it — the title bar (and its close button) may be hidden.
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var items: [NSView] = []
    /// Push current config values back into the controls (after a reset).
    private var refreshers: [() -> Void] = []
    private var targets: [ActionTarget] = []
    private let columnWidth: CGFloat = 620
    private var c: Config { .shared }

    override init() {
        let root = FlippedView()
        view = root
        window = ShojiWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Shoji Settings"
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        root.appearance = Config.shared.appearance
        window.applyWindowSettings(background: root)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        root.addSubview(scroll)
        doneButton.bezelStyle = .rounded
        doneButton.target = window
        doneButton.action = #selector(NSWindow.performClose(_:))
        root.addSubview(doneButton) // above the scrolling form
        root.onLayout = { [weak self] in self?.layout() }
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .configDidChange, object: nil)
    }

    // MARK: Building the form

    private func build() {
        header("Theme", "The same themes as Lucent for Hyprland")
        add(ThemeGridView())

        header("General", "Gaps, corners and focus")
        slider("Inner gaps", 0...30, step: 1, fmt: "%.0f px", get: { Double(self.c.gapsIn) }, set: { self.c.gapsIn = CGFloat($0) })
        slider("Outer gaps", 0...60, step: 1, fmt: "%.0f px", get: { Double(self.c.gapsOut) }, set: { self.c.gapsOut = CGFloat($0) })
        slider("Corner rounding", 0...30, step: 1, fmt: "%.0f px", get: { Double(self.c.rounding) }, set: { self.c.rounding = CGFloat($0) })
        popup("Modifier key", options: ModifierKey.allCases.map(\.title),
              get: { self.c.modifierKey.title },
              set: { t in self.c.modifierKey = ModifierKey.allCases.first { $0.title == t } ?? .option })
        toggle("Focus follows mouse", get: { self.c.focusFollowsMouse }, set: { self.c.focusFollowsMouse = $0 })
        toggle("Follow apps to their workspace", note: "Activating a window elsewhere (Dock, ⌘Tab) switches to its workspace",
               get: { self.c.focusOnActivate }, set: { self.c.focusOnActivate = $0 })

        header("Windows", "Applied to kitty, Shoji Machines, Shoji Containers and Stats")
        slider("Window opacity", 0.3...1, step: 0.01, fmt: "%.0f%%", scale: 100,
               get: { self.c.windowOpacity }, set: { self.c.windowOpacity = $0; self.scheduleWindowSettingsWrite() })
        toggle("Hide title bars", note: "No title bar or buttons (kitty: new windows). Mod+Q still closes them",
               get: { self.c.hideTitleBars }, set: { self.c.hideTitleBars = $0; self.scheduleWindowSettingsWrite() })

        header("Config file", "Keybindings, window rules and startup programs, hyprland.conf-style")
        let editButton = NSButton(title: "Edit shoji.conf", target: nil, action: nil)
        editButton.bezelStyle = .rounded
        bind(editButton) { UserConfig.edit() }
        row((UserConfig.url.path as NSString).abbreviatingWithTildeInPath,
            note: "Reloaded on save · errors show in a red banner", control: editButton, controlWidth: 130)

        header("Workspaces", "Floating workspaces let windows overlap and be moved freely")
        workspaceModes()

        header("Theme also changes", "Applied whenever you pick a theme")
        toggle("macOS appearance", note: "Dark or Light, to match the theme (macOS asks once to allow it)",
               get: { self.c.themeSetsAppearance }, set: { self.c.themeSetsAppearance = $0 })
        toggle("Wallpaper", note: "Lucent's starch lattice, dark or light",
               get: { self.c.themeSetsWallpaper }, set: { self.c.themeSetsWallpaper = $0 })
        toggle("kitty colours", note: "Writes ~/.config/kitty/theme.conf and reloads kitty (old file kept as theme.conf.before-shoji)",
               get: { self.c.themeSetsKitty }, set: { self.c.themeSetsKitty = $0 })
        toggle("macOS accent colour", note: "The nearest of macOS's eight accent colours",
               get: { self.c.themeSetsAccent }, set: { self.c.themeSetsAccent = $0 })
        let applyButton = NSButton(title: "Apply now", target: nil, action: nil)
        applyButton.bezelStyle = .rounded
        bind(applyButton) { if let t = ThemeLibrary.theme(Config.shared.themeID) { ThemeSync.apply(t) } }
        row("Apply the current theme", note: "Re-applies the four above", control: applyButton, controlWidth: 100)

        header("Programs", c.shortcut("What ⌥↩, ⌥B and ⌥N open"))
        appPopup("Terminal", candidates: Programs.terminals, get: { self.c.terminalApp }, set: { self.c.terminalApp = $0 })
        appPopup("Browser", candidates: ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
                                          "com.brave.Browser", "com.microsoft.edgemac", "app.zen-browser.zen"],
                 get: { self.c.browserApp }, set: { self.c.browserApp = $0 })
        appPopup("Editor", candidates: Programs.editors, get: { self.c.editorApp }, set: { self.c.editorApp = $0 })
        text("Always float", note: "Bundle ids, comma-separated",
             get: { self.c.floatApps.sorted().joined(separator: ", ") },
             set: { self.c.floatApps = Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) })

        footer()
    }

    /// Pass the window settings on to kitty a moment after the slider stops moving (each write
    /// reloads kitty). Shoji Machines picks them up from settings.json itself.
    private var windowSettingsWrite: DispatchWorkItem?
    private func scheduleWindowSettingsWrite() {
        windowSettingsWrite?.cancel()
        let work = DispatchWorkItem { ThemeSync.writeKittySettings() }
        windowSettingsWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// A popup of installed apps from `candidates` ("Automatic" = empty).
    private func appPopup(_ title: String, candidates: [String], get: @escaping () -> String, set: @escaping (String) -> Void) {
        let installed = candidates.filter(Programs.isInstalled)
        func name(_ id: String) -> String {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        }
        var options = ["Automatic"] + installed.map(name)
        let currentID = get()
        if !currentID.isEmpty, !installed.contains(currentID) { options.append(name(currentID)) }
        let ids = [""] + installed + (currentID.isEmpty || installed.contains(currentID) ? [] : [currentID])
        popup(title, options: options, get: { options[ids.firstIndex(of: get()) ?? 0] },
              set: { t in set(ids[options.firstIndex(of: t) ?? 0]) })
    }

    // MARK: Row builders

    private func header(_ title: String, _ subtitle: String?) {
        let v = RowView()
        let t = label(title, size: 15, weight: .semibold, color: c.text)
        v.addSubview(t)
        if let subtitle {
            let s = label(subtitle, size: 11.5, weight: .regular, color: c.overlay0)
            v.addSubview(s)
            s.frame.origin = CGPoint(x: 0, y: 44)
        }
        t.frame.origin = CGPoint(x: 0, y: 24)
        v.frame.size.height = subtitle == nil ? 52 : 66
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = c.surface0.cgColor
        v.addSubview(line)
        v.onLayout = { [weak v] in
            guard let v else { return }
            line.frame = CGRect(x: 0, y: v.bounds.height - 1, width: v.bounds.width, height: 1)
        }
        add(v)
    }

    /// A label on the left, `control` on the right.
    private func row(_ title: String, note: String? = nil, control: NSView, controlWidth: CGFloat, trailing: NSView? = nil) {
        let v = RowView()
        let l = label(title, size: 13, weight: .regular, color: c.subtext)
        v.addSubview(l)
        var n: NSTextField?
        if let note {
            let nl = label(note, size: 11, weight: .regular, color: c.overlay0)
            v.addSubview(nl)
            n = nl
        }
        v.addSubview(control)
        if let trailing { v.addSubview(trailing) }
        v.frame.size.height = note == nil ? 38 : 48
        v.onLayout = { [weak v] in
            guard let v else { return }
            let h = v.bounds.height
            l.frame.origin = CGPoint(x: 0, y: note == nil ? (h - l.frame.height) / 2 : 8)
            n?.frame.origin = CGPoint(x: 0, y: 27)
            let tw: CGFloat = trailing == nil ? 0 : 64
            let cx = v.bounds.width - controlWidth - tw
            let ch = control.fittingSize.height > 0 ? min(control.fittingSize.height, 28) : 22
            control.frame = CGRect(x: cx, y: (h - ch) / 2, width: controlWidth, height: ch)
            if let trailing {
                trailing.frame = CGRect(x: v.bounds.width - tw + 8, y: (h - trailing.frame.height) / 2,
                                        width: tw - 8, height: trailing.frame.height)
            }
        }
        add(v)
    }

    private func slider(_ title: String, _ range: ClosedRange<Double>, step: Double, fmt: String, scale: Double = 1,
                        get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        let s = NSSlider(value: get(), minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.isContinuous = true
        let value = label("", size: 12, weight: .medium, color: c.text, mono: true)
        value.alignment = .right
        let show = { value.stringValue = String(format: fmt, s.doubleValue * scale); value.sizeToFit() }
        show()
        bind(s) { [weak self] in
            let v = (s.doubleValue / step).rounded() * step
            set(v)
            show()
            self?.changed()
        }
        refreshers.append { s.doubleValue = get(); show() }
        row(title, control: s, controlWidth: 220, trailing: value)
    }

    private func toggle(_ title: String, note: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        let sw = NSSwitch()
        sw.state = get() ? .on : .off
        bind(sw) { [weak self] in set(sw.state == .on); self?.changed() }
        refreshers.append { sw.state = get() ? .on : .off }
        row(title, note: note, control: sw, controlWidth: 40)
    }

    private func color(_ title: String, get: @escaping () -> NSColor, set: @escaping (NSColor) -> Void) {
        let well = NSColorWell(frame: CGRect(x: 0, y: 0, width: 44, height: 24))
        if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
        well.color = get()
        bind(well) { [weak self] in
            NSColorPanel.shared.showsAlpha = true
            set(well.color)
            self?.changed()
        }
        refreshers.append { well.color = get() }
        row(title, control: well, controlWidth: 44)
    }

    private func popup(_ title: String, options: [String], get: @escaping () -> String, set: @escaping (String) -> Void) {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: options)
        let select = { if p.itemTitles.contains(get()) { p.selectItem(withTitle: get()) } else { p.selectItem(at: 0) } }
        select()
        bind(p) { [weak self] in set(p.titleOfSelectedItem ?? options[0]); self?.changed() }
        refreshers.append(select)
        row(title, control: p, controlWidth: 260)
    }

    private func text(_ title: String, note: String? = nil, get: @escaping () -> String, set: @escaping (String) -> Void) {
        let f = NSTextField(string: get())
        f.font = c.uiFont(12.5, weight: .regular)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        bind(f) { [weak self] in set(f.stringValue); self?.changed() }
        refreshers.append { f.stringValue = get() }
        row(title, note: note, control: f, controlWidth: 320)
    }

    private func workspaceModes() {
        let count = c.workspaceCount
        let seg = NSSegmentedControl(labels: (1...count).map(String.init), trackingMode: .selectAny, target: nil, action: nil)
        for i in 0..<count { seg.setWidth(26, forSegment: i) }
        let sync = { [weak self] in
            guard let self else { return }
            for i in 0..<count { seg.setSelected(self.c.floatingWorkspaces.contains(i + 1), forSegment: i) }
        }
        sync()
        bind(seg) { [weak self] in
            guard let self else { return }
            self.c.floatingWorkspaces = Set((0..<count).filter { seg.isSelected(forSegment: $0) }.map { $0 + 1 })
            self.changed()
        }
        refreshers.append(sync)
        row("Floating", note: "Selected workspaces float (new windows there float)",
            control: seg, controlWidth: CGFloat(count) * 27 + 6)
    }

    private func footer() {
        let v = RowView()
        let reset = NSButton(title: "Reset to defaults", target: nil, action: nil)
        bind(reset) { [weak self] in
            Config.shared.resetToDefaults()
            self?.refreshers.forEach { $0() }
        }
        reset.sizeToFit()
        let note = label("Saved automatically to " + (Config.settingsURL.path as NSString).abbreviatingWithTildeInPath,
                         size: 11, weight: .regular, color: c.overlay0)
        v.addSubview(reset)
        v.addSubview(note)
        v.frame.size.height = 90
        v.onLayout = { [weak v] in
            guard v != nil else { return }
            reset.frame.origin = CGPoint(x: 0, y: 32)
            note.frame.origin = CGPoint(x: reset.frame.maxX + 14, y: 32 + (reset.frame.height - note.frame.height) / 2)
        }
        add(v)
    }

    // MARK: Helpers

    private func add(_ v: NSView) {
        items.append(v)
        doc.addSubview(v)
    }

    private var applying = false

    private func changed() {
        applying = true
        c.notifyChanged()
        applying = false
        c.save()
    }

    func windowWillClose(_ notification: Notification) {
        WindowManager.shared?.releaseOwnWindow(window)
        SettingsWindow.current = nil
    }

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let t = ActionTarget(action)
        targets.append(t)
        control.target = t
        control.action = #selector(ActionTarget.fire)
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? c.monoUIFont(size, weight: weight) : c.uiFont(size, weight: weight)
        l.textColor = color
        l.sizeToFit()
        return l
    }

    private func layout() {
        scroll.frame = view.bounds
        doneButton.sizeToFit()
        doneButton.frame.origin = CGPoint(x: view.bounds.width - doneButton.frame.width - 16, y: 12)
        let width = max(320, min(columnWidth, view.bounds.width - 48))
        let x = (view.bounds.width - width) / 2
        var y: CGFloat = 8
        for v in items {
            let h = (v as? ThemeGridView)?.height(for: width) ?? v.frame.height
            v.frame = CGRect(x: x, y: y, width: width, height: h)
            v.needsLayout = true
            y += v.frame.height
        }
        doc.frame = CGRect(x: 0, y: 0, width: max(0, scroll.contentSize.width), height: y + 24)
    }

    /// Keep controls in sync when config changes elsewhere (reset, another window, a file load).
    private var builtTheme = Config.shared.themeID

    @objc private func configChanged() {
        window.applyWindowSettings(background: view)
        if c.themeID != builtTheme {
            builtTheme = c.themeID
            // Rebuild after the current event: the change may come from one of our own controls.
            DispatchQueue.main.async { [weak self] in self?.rebuildForTheme() }
            return
        }
        guard !applying else { return }
        refreshers.forEach { $0() }
    }

    /// Recreate every row in the new theme's colours, keeping the scroll position.
    private func rebuildForTheme() {
        let offset = scroll.contentView.bounds.origin
        items.forEach { $0.removeFromSuperview() }
        items.removeAll()
        refreshers.removeAll()
        targets.removeAll()
        view.appearance = c.appearance
        window.applyWindowSettings(background: view)
        build()
        layout()
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// Closure-backed target for NSControl actions.
final class ActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Flipped row that lays out its children via a closure.
final class RowView: NSView {
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
