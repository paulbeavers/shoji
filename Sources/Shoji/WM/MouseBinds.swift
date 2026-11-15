import AppKit

/// The event tap's C callback: hands mouse events to `MouseBinds` (on the main thread — the tap's
/// run-loop source is on the main run loop). Returning nil swallows the event.
private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let binds = Unmanaged<MouseBinds>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let e = event
    let swallow = MainActor.assumeIsolated { binds.handle(type, e) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Hyprland's mouse binds: Mod + left-drag moves a window, Mod + right-drag resizes it, from
/// anywhere inside the window. Floating windows move and resize freely; a tiled window follows
/// the pointer and swaps with the tile it's dropped on, and resizing it moves its split borders.
/// A session event tap (covered by the Accessibility permission) sees the clicks first, so the
/// app under the pointer never gets them.
@MainActor
final class MouseBinds {
    private var tap: CFMachPort?
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
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// True = swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) } // macOS turns slow taps off; back on
            return false
        case .leftMouseDown, .rightMouseDown:
            guard drag == nil, modifierHeld(event.flags), let wm = WindowManager.shared else { return false }
            let p = event.location // global, top-left origin = AX coordinates
            guard let w = wm.managedWindow(at: p) else { return false }
            let frame = (w.isFloating ? w.frame : wm.tileRect(of: w)) ?? w.frame ?? .zero
            drag = Drag(window: w, resize: type == .rightMouseDown, start: p, startFrame: frame,
                        left: p.x < frame.midX, top: p.y < frame.midY)
            wm.focus(w)
            return true
        case .leftMouseDragged, .rightMouseDragged:
            guard let d = drag else { return false }
            // ~60 updates a second: each one is an Accessibility call into another app.
            if Date().timeIntervalSince(lastUpdate) > 0.016 {
                lastUpdate = Date()
                update(d, to: event.location)
            }
            return true
        case .leftMouseUp, .rightMouseUp:
            guard let d = drag else { return false }
            drag = nil
            update(d, to: event.location)
            if !d.window.isFloating, !d.resize { WindowManager.shared?.mouseDropTiled(d.window, at: event.location) }
            WindowManager.shared?.mouseDragEnded()
            return true
        default:
            return false
        }
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

    /// Exactly Shoji's modifier (⌥, ⌃⌥ or ⌘) — no extra ⌘/⌃/⌥, so normal ⌘-clicks etc. pass.
    private func modifierHeld(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let want: CGEventFlags
        switch Config.shared.modifierKey {
        case .option: want = .maskAlternate
        case .controlOption: want = [.maskAlternate, .maskControl]
        case .command: want = .maskCommand
        }
        return flags.intersection(relevant) == want
    }
}
