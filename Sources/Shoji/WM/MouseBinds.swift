import AppKit

/// What the event tap's thread needs to know without touching the main thread: whether mouse
/// binds are on, which modifier flags they want, and whether a drag is in progress.
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true
    private var _want: CGEventFlags = .maskAlternate
    private var _dragging = false
    private var _latest: CGPoint?
    private var _updateScheduled = false

    func configure(enabled: Bool, want: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        _enabled = enabled
        _want = want
    }

    /// Exactly the configured modifier: no extra ⌘/⌃/⌥/⇧, so ⌘-clicks, ⇧⌥-clicks etc. pass.
    func wantsClick(_ flags: CGEventFlags) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return _enabled && !_dragging && flags.intersection(relevant) == _want
    }

    var dragging: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _dragging }
        set { lock.lock(); _dragging = newValue; if !newValue { _latest = nil }; lock.unlock() }
    }

    /// Record the newest drag point; true if the main thread needs a new update scheduled
    /// (one is not already pending — points coalesce while the main thread is busy).
    func noteDrag(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _latest = p
        if _updateScheduled { return false }
        _updateScheduled = true
        return true
    }

    /// Put a point back that was taken too early (throttled), unless a newer one arrived.
    func requeue(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _dragging else { return false }
        if _latest == nil { _latest = p }
        if _updateScheduled { return false }
        _updateScheduled = true
        return true
    }

    func takeLatest() -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        _updateScheduled = false
        let p = _latest
        _latest = nil
        return p
    }
}

private let tapState = TapState()

/// The event tap's C callback, on the tap's own thread: every click on the Mac passes through it,
/// so it never waits for Shoji's main thread (which can be stuck in a slow Accessibility call)
/// unless the click is a Mod+click. Returning nil swallows the event.
private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let binds = Unmanaged<MouseBinds>.fromOpaque(refcon).takeUnretainedValue()
    let p = event.location // global, top-left origin = AX coordinates
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // macOS turns slow taps off: back on, and drop a drag whose mouse-up we may have missed.
        binds.reenable()
        if tapState.dragging {
            tapState.dragging = false
            DispatchQueue.main.async { MainActor.assumeIsolated { binds.cancel() } }
        }
        return pass
    case .leftMouseDown, .rightMouseDown:
        guard tapState.wantsClick(event.flags) else { return pass }
        let resize = type == .rightMouseDown
        let started = DispatchQueue.main.sync { MainActor.assumeIsolated { binds.begin(at: p, resize: resize) } }
        if started { tapState.dragging = true }
        return started ? nil : pass
    case .leftMouseDragged, .rightMouseDragged:
        guard tapState.dragging else { return pass }
        if tapState.noteDrag(p) {
            DispatchQueue.main.async { MainActor.assumeIsolated { binds.dragged() } }
        }
        return nil
    case .leftMouseUp, .rightMouseUp:
        guard tapState.dragging else { return pass }
        tapState.dragging = false
        DispatchQueue.main.async { MainActor.assumeIsolated { binds.end(at: p) } }
        return nil
    default:
        return pass
    }
}

/// Hyprland's mouse binds: Mod + left-drag moves a window, Mod + right-drag resizes it, from
/// anywhere inside the window. Floating windows move and resize freely; a tiled window follows
/// the pointer and swaps with the tile it's dropped on, and resizing it moves its split borders.
/// A session event tap (covered by the Accessibility permission) sees the clicks first, so the
/// app under the pointer never gets them. Off in Settings → General → Mouse binds.
@MainActor
final class MouseBinds {
    nonisolated(unsafe) private var tap: CFMachPort?
    private var drag: Drag?
    private var lastUpdate = Date.distantPast

    private struct Drag {
        let window: ManagedWindow
        let resize: Bool
        let start: CGPoint
        let startFrame: CGRect
        /// Which edges a resize moves: the ones nearest where the drag started.
        let left: Bool
        let top: Bool
    }

    func install() {
        configure()
        NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ShojiLog.write("mouse binds: couldn't create the event tap (Accessibility permission?)")
            return
        }
        self.tap = tap
        // The tap's own thread and run loop (lives as long as Shoji).
        nonisolated(unsafe) let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        nonisolated(unsafe) let port = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Shoji mouse binds"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Pass the setting and modifier to the tap's thread.
    private func configure() {
        let want: CGEventFlags
        switch Config.shared.modifierKey {
        case .option: want = .maskAlternate
        case .controlOption: want = [.maskAlternate, .maskControl]
        case .command: want = .maskCommand
        }
        tapState.configure(enabled: Config.shared.mouseBinds, want: want)
    }

    nonisolated fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// A Mod+click: true if it starts a drag (and the click is swallowed).
    fileprivate func begin(at p: CGPoint, resize: Bool) -> Bool {
        guard let wm = WindowManager.shared, let w = wm.managedWindow(at: p), !wm.isFullscreen(w) else { return false }
        // A tiled resize works on the tile's rect (it moves split borders); a move follows the
        // window's real frame, which can differ from its tile (apps that snap their size).
        let frame = (resize && !w.isFloating ? wm.tileRect(of: w) : w.frame) ?? w.frame ?? .zero
        drag = Drag(window: w, resize: resize, start: p, startFrame: frame,
                    left: p.x < frame.midX, top: p.y < frame.midY)
        lastUpdate = .distantPast
        wm.focus(w)
        return true
    }

    fileprivate func dragged() {
        guard let p = tapState.takeLatest(), let d = drag else { return }
        // At most ~60 updates a second: each one is an Accessibility call into another app.
        let wait = 0.016 - Date().timeIntervalSince(lastUpdate)
        if wait > 0 {
            if tapState.requeue(p) {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.dragged() }
            }
            return
        }
        lastUpdate = Date()
        update(d, to: p)
    }

    fileprivate func end(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        update(d, to: p)
        if !d.window.isFloating, !d.resize { WindowManager.shared?.mouseDropTiled(d.window, at: p) }
        WindowManager.shared?.mouseDragEnded()
    }

    /// The tap was switched off mid-drag: settle where the window is.
    fileprivate func cancel() {
        guard drag != nil else { return }
        drag = nil
        WindowManager.shared?.mouseDragEnded()
    }

    private func update(_ d: Drag, to p: CGPoint) {
        guard let wm = WindowManager.shared else { return }
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        if !d.resize {
            if d.window.isFloating {
                wm.mouseSetFloatingFrame(d.window, d.startFrame.offsetBy(dx: dx, dy: dy))
            } else {
                wm.mouseMoveTiled(d.window, origin: CGPoint(x: d.startFrame.minX + dx, y: d.startFrame.minY + dy))
            }
            return
        }
        // Resize from the nearest corner.
        var r = d.startFrame
        let minW: CGFloat = 160, minH: CGFloat = 100
        if d.left {
            let w = max(minW, r.width - dx)
            r.origin.x = r.maxX - w
            r.size.width = w
        } else {
            r.size.width = max(minW, r.width + dx)
        }
        if d.top {
            let h = max(minH, r.height - dy)
            r.origin.y = r.maxY - h
            r.size.height = h
        } else {
            r.size.height = max(minH, r.height + dy)
        }
        if d.window.isFloating { wm.mouseSetFloatingFrame(d.window, r) } else { wm.mouseResizeTiled(d.window, to: r) }
    }
}
