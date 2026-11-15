import AppKit

/// Shoji's workspaces in the macOS menu bar: a row of pills (the active one in the theme's
/// gradient, occupied ones filled, empty ones just a number). Click a pill to switch; right-click
/// (or click beside the pills) for the menu.
///
/// macOS (26 and later) draws its own pressed highlight on any menu bar item that's clicked, and no
/// app can turn it off — so the pills aren't the status item itself. The status item is a blank
/// placeholder that reserves the space (macOS still decides where it goes among the other items);
/// the pills are drawn in Shoji's own small panel lying exactly over it, which takes the clicks.
@MainActor
final class WorkspaceMenu: NSObject {
    static private(set) var shared: WorkspaceMenu?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var states: [(index: Int, occupied: Bool, active: Bool)] = []
    /// Pill rects in image coordinates (x only matters), for click hit-testing.
    private var pillRanges: [(index: Int, minX: CGFloat, maxX: CGFloat)] = []
    private var imageWidth: CGFloat = 0
    private var placeholderWidth: CGFloat = -1
    private var menuTargets: [MenuTarget] = []
    private let panel = PillsPanel()
    private var pillsView: PillsView { panel.pills }
    private var syncTimer: Timer?

    override init() {
        super.init()
        Self.shared = self
        item.button?.imagePosition = .imageOnly
        pillsView.onClick = { [weak self] isMenuClick, x in self?.clicked(menu: isMenuClick, x: x) }
        NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        // Follow the placeholder: it moves when other menu bar items come and go, and its window
        // disappears with the menu bar (full-screen apps). Notifications cover most of it; a light
        // poll catches the rest.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, (n.object as? NSWindow) === self.item.button?.window else { return }
                    self.syncPanel()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanel() }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanel() }
        }
        refresh()
    }

    func refresh() {
        guard let wm = WindowManager.shared else { return }
        let new = wm.workspaceStates
        guard new.map({ "\($0.index)\($0.occupied)\($0.active)" }) != states.map({ "\($0.index)\($0.occupied)\($0.active)" })
            || pillsView.image == nil else { return }
        states = new
        redraw()
    }

    private func redraw() {
        pillsView.image = Self.image(for: states, ranges: &pillRanges, width: &imageWidth)
        // The placeholder only changes size when a pill is added or removed.
        if abs(placeholderWidth - imageWidth) > 0.5, let button = item.button {
            placeholderWidth = imageWidth
            button.image = NSImage(size: CGSize(width: imageWidth, height: 22))
            DispatchQueue.main.async { [weak self] in self?.syncPanel() }
        }
    }

    /// Put the panel exactly over the placeholder; hide it when the menu bar isn't showing.
    private func syncPanel() {
        guard let window = item.button?.window else { panel.orderOut(nil); return }
        let visible = window.isVisible && window.occlusionState.contains(.visible) && window.frame.width > 0
        guard visible else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        // Labels follow the menu bar's own light/dark look (it depends on the wallpaper).
        if let look = item.button?.effectiveAppearance, panel.appearance?.name != look.name {
            panel.appearance = look
            pillsView.needsDisplay = true
        }
        if panel.frame != window.frame { panel.setFrame(window.frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The pills, drawn at display time so labels follow the menu bar's light/dark appearance.
    static func image(for states: [(index: Int, occupied: Bool, active: Bool)],
                      ranges: inout [(index: Int, minX: CGFloat, maxX: CGFloat)], width: inout CGFloat) -> NSImage {
        let c = Config.shared
        let h: CGFloat = 16, gap: CGFloat = 4
        var x: CGFloat = 0
        var layout: [(Int, Bool, Bool, CGRect)] = []
        for s in states {
            let w: CGFloat = s.active ? 28 : 18
            layout.append((s.index, s.occupied, s.active, CGRect(x: x, y: 3, width: w, height: h)))
            x += w + gap
        }
        // A settings gear after the pills (range index 0 = the gear).
        let gearSymbol = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Shoji Settings")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        let gearSize = gearSymbol?.size ?? CGSize(width: 14, height: 14)
        let gearRect = CGRect(x: x + 4, y: ((22 - gearSize.height) / 2).rounded(), width: gearSize.width, height: gearSize.height)
        width = gearRect.maxX + 1
        ranges = layout.map { ($0.0, $0.3.minX, $0.3.maxX) } + [(0, gearRect.minX - 3, gearRect.maxX + 3)]
        let gradient = c.activeBorder
        let activeText = c.crust
        let image = NSImage(size: CGSize(width: width, height: 22), flipped: false) { _ in
            let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
            for (index, occupied, active, r) in layout {
                let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                let textColor: NSColor
                if active {
                    NSGradient(colors: gradient)?.draw(in: path, angle: 0)
                    textColor = activeText
                } else if occupied {
                    NSColor.labelColor.withAlphaComponent(0.18).setFill()
                    path.fill()
                    textColor = .labelColor
                } else {
                    textColor = .secondaryLabelColor
                }
                let label = NSAttributedString(string: "\(index % 10)", attributes: [.font: font, .foregroundColor: textColor])
                let size = label.size()
                label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            }
            if let gearSymbol {
                // Tint the symbol with the menu bar's text colour (resolved at draw time).
                NSGraphicsContext.saveGraphicsState()
                gearSymbol.draw(in: gearRect)
                NSColor.labelColor.withAlphaComponent(0.85).set()
                gearRect.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func clicked(menu isMenuClick: Bool, x viewX: CGFloat) {
        let x = viewX - (pillsView.bounds.width - imageWidth) / 2
        let hit = isMenuClick ? nil : pillRanges.first(where: { x >= $0.minX - 2 && x <= $0.maxX + 2 })
        DispatchQueue.main.async { [weak self] in
            if let hit, hit.index == 0 {
                SettingsWindow.show()
            } else if let hit {
                WindowManager.shared?.switchTo(hit.index)
            } else {
                self?.showMenu()
            }
        }
    }

    private func showMenu() {
        let c = Config.shared
        let menu = NSMenu()
        menuTargets = []
        func add(_ title: String, key: String = "", checked: Bool = false, _ action: @escaping () -> Void) {
            let t = MenuTarget(action)
            menuTargets.append(t)
            let i = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            i.target = t
            i.state = checked ? .on : .off
            if !key.isEmpty { i.title = "\(title)\t\(key)" }
            menu.addItem(i)
        }
        for s in states {
            add("Workspace \(s.index)" + (s.occupied ? "" : "  (empty)"), key: "\(c.modSymbol)\(s.index % 10)", checked: s.active) {
                WindowManager.shared?.switchTo(s.index)
            }
        }
        menu.addItem(.separator())
        add("App Launcher…", key: "\(c.modSymbol)⇧D") { Launcher.shared.show() }
        add("Keybindings", key: "\(c.modSymbol)/") { HelpPanel.toggle() }
        add("Settings…", key: "\(c.modSymbol),") { SettingsWindow.show() }
        menu.addItem(.separator())
        add("Quit Shoji", key: "\(c.modSymbol)⇧M") { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: pillsView)
    }
}

/// The borderless, non-activating panel the pills live in, one level above the menu bar's items.
final class PillsPanel: NSPanel {
    let pills = PillsView(frame: .zero)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Take clicks everywhere, transparent pixels included. By default macOS passes clicks on
        // fully transparent parts of a window through — an empty workspace is just a number, so
        // the click went to the menu bar item underneath (which flashed and didn't switch).
        ignoresMouseEvents = false
        pills.autoresizingMask = [.width, .height]
        contentView = pills
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the workspace pills and takes their clicks.
final class PillsView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    /// (menu?, x in the view): menu = right-click / control-click.
    var onClick: ((Bool, CGFloat) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.control), convert(event.locationInWindow, from: nil).x)
    }
    override func rightMouseDown(with event: NSEvent) { onClick?(true, convert(event.locationInWindow, from: nil).x) }

    override func draw(_ dirtyRect: NSRect) {
        // An all-but-invisible fill, so no pixel of the panel counts as transparent for clicks.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        guard let image else { return }
        image.draw(in: CGRect(x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded(),
                              width: image.size.width, height: image.size.height))
    }
}

/// Closure-backed target for menu items.
final class MenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
}
