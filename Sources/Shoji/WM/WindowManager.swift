import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility notifications arrive here (a plain C callback) and go to the window manager.
private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let notification = name as String
    MainActor.assumeIsolated {
        Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().handle(notification, element)
    }
}

/// The tiling window manager: tracks every regular app's windows through the Accessibility API,
/// arranges them per workspace (dwindle), and runs the bindings' commands.
@MainActor
final class WindowManager {
    static private(set) var shared: WindowManager!

    private(set) var workspaces: [Workspace] = []
    private(set) var current: Workspace
    private var windows: [CGWindowID: ManagedWindow] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    /// Windows that exist but aren't laid out (minimized, app hidden).
    private var dormant = Set<CGWindowID>()
    private(set) var focusedID: CGWindowID?
    private var previousFocusedID: CGWindowID?
    private var settleWork: [CGWindowID: DispatchWorkItem] = [:]
    /// The next window from this app floats (Mod+Shift+Return's floating terminal).
    private var pendingFloat: (bundleID: String, until: Date)?
    /// Ignore "app activated a window elsewhere" right after we switched workspaces ourselves.
    private var ignoreActivationUntil = Date.distantPast
    /// When a window on the visible workspace last closed (see `systemFocused`).
    private var closedHereAt = Date.distantPast
    private var mouseMonitor: Any?
    private var lastHover = Date.distantPast
    private var c: Config { .shared }

    /// Bar and dock refresh hook.
    var onChange: (() -> Void)?

    init() {
        for i in 1...Config.shared.workspaceCount { workspaces.append(Workspace(index: i)) }
        current = workspaces[0]
        Self.shared = self
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.recentLaunches[app.processIdentifier] = Date()
                // Watch closely for its first window; an app's Accessibility interface is ready a
                // moment after launch, so also look again a little later.
                if let id = app.bundleIdentifier { self?.expectWindow(of: id, for: 5) }
                for delay in [0.3, 1.0, 2.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.observe(app) }
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.forget(pid: app.processIdentifier) }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        NotificationCenter.default.addObserver(forName: .configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    func start() {
        restoring = SessionFile.load()
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        finishRestore()
        relayout()
        if let app = NSWorkspace.shared.frontmostApplication { appActivated(app) }
        installMouseMonitor()
        notifyChange()
        // The Dock showing, hiding, moving or resizing changes the free area; macOS doesn't always
        // announce it, so check now and then.
        lastVisibleFrame = screen.visibleFrame
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The frontmost app, and apps launched in the last minute (slow starters like Adobe
                // Bridge and NX Studio show their real window late, often while not frontmost), may
                // have opened a window without telling anyone.
                self.recentLaunches = self.recentLaunches.filter { Date().timeIntervalSince($0.value) < 60 }
                var pids = Set(self.recentLaunches.keys).union(self.appsWithUnmanagedWindows())
                if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.insert(front) }
                for pid in pids {
                    guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                    if self.appElements[pid] == nil { self.observe(app) }
                    if let el = self.appElements[pid] {
                        self.scanWindows(of: pid, appElement: el, name: app.localizedName ?? "?", areNew: true)
                    }
                }
                guard self.screen.visibleFrame != self.lastVisibleFrame else { return }
                self.lastVisibleFrame = self.screen.visibleFrame
                self.relayout()
            }
        }
    }

    private var lastVisibleFrame: CGRect = .zero

    // MARK: Geometry

    var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// The screen minus the macOS menu bar and Dock (wherever it sits; when it auto-hides, nothing).
    var usableFrame: CGRect { AX.axRect(fromScreen: screen.visibleFrame) }

    /// The tiling area in AX coordinates: the usable frame inside the outer gaps.
    var area: CGRect { usableFrame.insetBy(dx: c.gapsOut, dy: c.gapsOut) }

    /// Where windows of hidden workspaces wait: their top-left at the screen's bottom-right
    /// corner, so (almost) nothing of them shows.
    private var parkPoint: CGPoint {
        let full = AX.axRect(fromScreen: screen.frame)
        return CGPoint(x: full.maxX - 1, y: full.maxY - 1)
    }

    private func isParkedPosition(_ r: CGRect) -> Bool {
        abs(r.minX - parkPoint.x) < 4 && abs(r.minY - parkPoint.y) < 4
    }

    // MARK: Apps and windows

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid() else { return }
        if observers[pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 1.0) // a hung app mustn't freeze Shoji for long
            var failed = false
            for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                      kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                let err = AXObserverAddNotification(obs, appElement, n as CFString, refcon)
                if err != .success && err != .notificationAlreadyRegistered && err != .notificationUnsupported { failed = true }
            }
            // Looked at the instant it launched, an app may not be able to register yet: try again
            // shortly (watchExpected does) rather than keep an observer that never hears anything.
            // An older app that still refuses (busy) keeps what worked, as before.
            if failed, let t = recentLaunches[pid], Date().timeIntervalSince(t) < 5 { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = obs
            appElements[pid] = appElement
        }
        guard let appElement = appElements[pid] else { return }
        // Windows of an app that has just launched are new windows (focus them).
        let justLaunched = recentLaunches[pid].map { Date().timeIntervalSince($0) < 15 } ?? false
        scanWindows(of: pid, appElement: appElement, name: app.localizedName ?? "pid \(pid)", areNew: justLaunched)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    // MARK: Shoji's own tiled windows (Stats)

    /// Shoji's own windows that are tiled like app windows. Its other windows (Settings, the
    /// launcher, the keybindings sheet) are never managed.
    private var ownTiled = Set<CGWindowID>()

    /// Tile one of Shoji's own windows (already on screen) into the current workspace.
    func tileOwnWindow(_ window: NSWindow, attempt: Int = 0) {
        let id = CGWindowID(window.windowNumber)
        if let w = windows[id] { focus(w); return }
        let pid = getpid()
        if observers[pid] == nil { // per-window notifications only; no app-level ones for Shoji
            var obs: AXObserver?
            guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = obs
            appElements[pid] = AXUIElementCreateApplication(pid)
        }
        guard let app = appElements[pid],
              let e = AX.windows(ofApp: app).first(where: { AX.windowID($0) == id }) else {
            if attempt < 5 { // the AX side of a just-shown window can lag a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.tileOwnWindow(window, attempt: attempt + 1) }
            }
            return
        }
        ownTiled.insert(id)
        addWindow(e, pid: pid, isNew: true)
    }

    /// One of Shoji's own tiled windows closed: take it out of the layout.
    func releaseOwnWindow(_ window: NSWindow) {
        let id = CGWindowID(window.windowNumber)
        ownTiled.remove(id)
        if let w = windows[id] { removeWindow(w) }
    }

    func isFocused(_ window: NSWindow) -> Bool { focusedID == CGWindowID(window.windowNumber) }

    private func forget(pid: pid_t) {
        for w in windows.values where w.pid == pid { removeWindow(w) }
        scanReports[pid] = nil
        recentLaunches[pid] = nil
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        appElements[pid] = nil
        notifyChange()
    }

    private func lookup(_ e: AXUIElement) -> ManagedWindow? {
        if let id = AX.windowID(e), let w = windows[id] { return w }
        return windows.values.first { CFEqual($0.element, e) }
    }

    /// A window we never heard being created (some apps — Chrome, Electron — announce new windows
    /// late or not at all): pick it up when it gets focus.
    private func adopt(_ e: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        addWindow(e, pid: pid)
        if let w = lookup(e) { setFocused(w) }
    }

    /// Manage a window. `isNew`: it just opened (focus it, as Hyprland does). Windows that aren't
    /// fully formed yet (no id, no subrole — some apps fill these in a moment later) are retried.
    private func addWindow(_ e: AXUIElement, pid: pid_t, isNew: Bool = false, attempt: Int = 0, retries: Bool = true) {
        if pid == getpid(), !(AX.windowID(e).map { ownTiled.contains($0) } ?? false) { return } // Settings etc.
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        func retryLater(_ why: String) {
            guard retries else { return } // the caller looks again soon anyway
            guard attempt < 3 else { ShojiLog.write("ignored \(appName): \(why)"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + [0.25, 0.6, 1.2][attempt]) { [weak self] in
                self?.addWindow(e, pid: pid, isNew: isNew, attempt: attempt + 1)
            }
        }
        let role = AX.string(e, kAXRoleAttribute) ?? ""
        if role.isEmpty { retryLater("no role yet"); return }
        // Sheets, drawers, popovers, menus and tooltips belong to a window; never manage them.
        let attached: Set<String> = [kAXSheetRole as String, kAXDrawerRole as String, "AXPopover", kAXMenuRole as String,
                                     kAXHelpTagRole as String]
        guard !attached.contains(role) else { return }
        // Some toolkits mislabel their windows: Adobe Bridge's main window is an "AXLayoutArea" with
        // subrole "AXFloatingWindow". Anything else with its own window-server id is a real
        // top-level window.
        let mislabelled = role != kAXWindowRole as String
        guard let id = AX.windowID(e) else {
            if mislabelled { ShojiLog.write("skipped \(appName): role \(role) without a window id") } else { retryLater("no window id") }
            return
        }
        guard windows[id] == nil else { return }
        let subrole = AX.string(e, kAXSubroleAttribute) ?? ""
        let resizable = AX.isSettable(e, kAXSizeAttribute)
        let closable = AX.element(e, kAXCloseButtonAttribute) != nil
        // Apps with their own toolkits (NX Studio, some Java/Qt/game-engine apps) report no subrole
        // or "AXUnknown" for ordinary windows — at first, or always — and mislabelled ones' subroles
        // can't be trusted either. Treat a window that can be closed or resized as an ordinary one.
        let unknown = subrole.isEmpty || subrole == kAXUnknownSubrole as String || mislabelled
        if unknown && !(resizable || closable) { retryLater("subrole \(subrole.isEmpty ? "none" : subrole), not resizable/closable"); return }
        let standard = subrole == kAXStandardWindowSubrole as String || unknown
        // Dialogs float; sheets, popovers, tooltips and the like aren't windows we manage.
        guard standard || subrole == kAXDialogSubrole as String || subrole == kAXFloatingWindowSubrole as String else {
            ShojiLog.write("ignored \(appName): subrole \(subrole)")
            return
        }
        if AX.bool(e, "AXFullScreen") == true { ShojiLog.write("ignored \(appName): native full screen"); return }
        guard let frame = AX.frame(e) else { retryLater("no frame"); return }
        // Only the main display is managed for now; windows elsewhere are left alone.
        let main = AX.axRect(fromScreen: screen.frame)
        guard main.contains(CGPoint(x: frame.midX, y: frame.midY)) || isParkedPosition(frame) else {
            ShojiLog.write("ignored \(appName): on another display \(frame)")
            return
        }

        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        // Floats by its nature (dialog, fixed size, always-float app) or by its workspace's layout.
        let floatsByNature = !standard || !resizable || c.floatApps.contains(bundle)
        var floating = floatsByNature || current.isFloatingMode
        var floatFrame = frame
        if let p = pendingFloat, p.bundleID == bundle, p.until > Date() {
            floating = true
            pendingFloat = nil
            let a = area
            floatFrame = CGRect(x: a.midX - 500, y: a.midY - 325, width: 1000, height: 650)
        }
        if isParkedPosition(frame) { // left parked by a crashed Shoji: bring it back
            floatFrame = CGRect(x: area.minX + 40, y: area.minY + 40, width: frame.width, height: frame.height)
        }
        // shoji.conf window rules (not for windows coming back from a restart).
        let title = AX.string(e, kAXTitleAttribute) ?? ""
        let rule = UserConfig.shared.rules(app: appName, bundle: bundle, title: title)
        if restoring?.placement(of: id, pid: pid) == nil {
            // A `workspace N` rule: the layout of workspace N decides, not the current one's.
            if let n = rule.workspace, let target = workspace(index: n) { floating = floatsByNature || target.isFloatingMode }
            if rule.float { floating = true }
            if rule.tile { floating = false }
            if let size = rule.size {
                let a = area
                floatFrame = CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
            } else if rule.center {
                let a = area
                floatFrame = CGRect(x: a.midX - frame.width / 2, y: a.midY - frame.height / 2, width: frame.width, height: frame.height)
            }
        }
        // Restarting: put the window back where it was (workspace, floating frame, pin).
        let saved = restoring?.placement(of: id, pid: pid)
        if let saved {
            floating = saved.floating != nil
            if let f = saved.floating, f.frame.count == 4 {
                floatFrame = CGRect(x: f.frame[0], y: f.frame[1], width: f.frame[2], height: f.frame[3])
            }
        }
        ShojiLog.write("new window: \(appName) [\(bundle)] \(floating ? "floating" : "tiling") role=\(role) subrole=\(subrole.isEmpty ? "none" : subrole) "
            + "resizable=\(resizable) closable=\(closable) frame=\(frame)")

        let w = ManagedWindow(id: id, pid: pid, element: e, workspace: current.index, floating: floating)
        w.floatFrame = floatFrame
        windows[id] = w
        expected[bundle] = nil // the window we were watching for
        if let obs = observers[pid] {
            for n in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(obs, e, n as CFString, refcon)
            }
        }
        if AX.bool(e, kAXMinimizedAttribute) == true {
            ShojiLog.write("\(appName): window is minimized; tiled when restored")
            dormant.insert(id)
            return
        }
        // A `workspace N [silent]` rule.
        if saved == nil, let n = rule.workspace, let ws = workspaces.first(where: { $0.index == n }), ws !== current {
            place(w, in: ws)
            park(w, keepFloatFrame: true) // the frame a size/center rule chose, not its launch frame
            if isNew && !rule.silent { switchTo(n, focusing: w) }
            notifyChange()
            return
        }
        if let saved, let ws = workspace(index: saved.workspace) {
            w.isPinned = saved.floating?.pinned ?? false
            if floating {
                place(w, in: ws)
            } else {
                w.workspace = ws.index
                restoredTiled[id] = w // its tree is rebuilt in finishRestore()
            }
            return
        }
        place(w, in: current)
        relayout()
        // A window that just opened gets focus and comes to the front (floating ones especially
        // must not open behind the tiles).
        if isNew { focus(w) }
        notifyChange()
        // New windows often size themselves a moment after appearing; tile them again once they've
        // settled (relayout only touches windows that are off).
        for delay in [0.3, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.windows[id] != nil, w.workspace == self.current.index, !w.isFloating,
                      NSEvent.pressedMouseButtons == 0 else { return }
                self.relayout()
            }
        }
    }

    /// Put a window into a workspace's layout.
    private func place(_ w: ManagedWindow, in ws: Workspace) {
        w.workspace = ws.index
        if w.isFloating {
            ws.floating.append(w)
            if ws === current, let f = w.floatFrame { w.setFrame(f) }
        } else {
            ws.tree.insert(w, near: ws.focused.flatMap { $0.isFloating ? nil : $0 })
        }
    }

    private func removeWindow(_ w: ManagedWindow) {
        let wasHere = !w.isParked && (current.contains(w) || w.isPinned)
        let hadFocus = focusedID == w.id
        if wasHere { closedHereAt = Date() }
        windows[w.id] = nil
        dormant.remove(w.id)
        settleWork.removeValue(forKey: w.id)?.cancel()
        for ws in workspaces { ws.remove(w) }
        if focusedID == w.id { focusedID = nil }
        relayout()
        notifyChange()
        // Like Hyprland: focus moves to the next window on this workspace — not to wherever the
        // app (or macOS) puts it, which may be a window parked on another workspace.
        if wasHere, hadFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.focusedID == nil || self.focused.map({ !self.current.contains($0) && !$0.isPinned }) == true,
                      let next = self.current.focused, !self.dormant.contains(next.id) else { return }
                self.focus(next)
            }
        }
    }

    /// Minimized or hidden: out of the layout, but still known.
    private func setDormant(_ w: ManagedWindow, _ on: Bool) {
        if on {
            guard !dormant.contains(w.id) else { return }
            dormant.insert(w.id)
            // (A parked window's frame is the park point, not where it belongs.)
            if w.isFloating, !w.isParked, let f = w.frame { w.floatFrame = f }
            containing(w)?.remove(w)
        } else {
            guard dormant.remove(w.id) != nil else { return }
            // An app shown again (⌘H undone) with a window that's still minimized: it stays out.
            if AX.bool(w.element, kAXMinimizedAttribute) == true { dormant.insert(w.id); return }
            // Back on its own workspace — not wherever the user happens to be.
            let home = w.isPinned ? current : (workspace(index: w.workspace) ?? current)
            w.isParked = false
            place(w, in: home)
            if home !== current { park(w, keepFloatFrame: true) }
        }
        relayout()
        notifyChange()
    }

    // MARK: Accessibility events

    fileprivate func handle(_ name: String, _ e: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            addWindow(e, pid: pid, isNew: true)
        case kAXUIElementDestroyedNotification:
            if let w = lookup(e) { removeWindow(w) }
        case kAXFocusedWindowChangedNotification:
            if let w = lookup(e) { systemFocused(w) } else { adopt(e) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let w = lookup(e) { userMoved(w) }
        case kAXWindowMiniaturizedNotification:
            if let w = lookup(e) { setDormant(w, true) }
        case kAXWindowDeminiaturizedNotification:
            if let w = lookup(e) { setDormant(w, false) }
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            for w in windows.values where w.pid == pid { setDormant(w, name == kAXApplicationHiddenNotification) }
        case kAXTitleChangedNotification:
            if let w = lookup(e), w.id == focusedID { notifyChange() }
        default:
            break
        }
    }

    private func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if observers[pid] == nil { observe(app) } else if let appElement = appElements[pid] {
            // Apps that never announce new windows: catch them whenever the app comes forward.
            scanWindows(of: pid, appElement: appElement, name: app.localizedName ?? "pid \(pid)", areNew: true)
        }
        guard let appElement = appElements[pid], let e = AX.element(appElement, kAXFocusedWindowAttribute) else { return }
        if let w = lookup(e) { systemFocused(w) } else { adopt(e) }
    }

    /// Apps with more normal windows on screen than Shoji manages for them — a window that slipped
    /// past (Adobe Bridge's main window: its app was too busy to answer when it opened). Asks the
    /// window server, which needs no permission. Such a window would otherwise show on every
    /// workspace, since only managed windows get parked.
    private func appsWithUnmanagedWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let main = screen.frame // CG bounds are top-left based like AX; only size and position matter here
        let mainAX = AX.axRect(fromScreen: main)
        var counts: [pid_t: Int] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"], w >= 200, h >= 150,
                  let x = b["X"], let y = b["Y"], mainAX.contains(CGPoint(x: x + w / 2, y: y + h / 2)) else { continue }
            counts[pid, default: 0] += 1
        }
        var result = Set<pid_t>()
        for (pid, n) in counts where observers[pid] != nil || NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
            let managed = windows.values.filter { $0.pid == pid && !$0.isParked && !dormant.contains($0.id) }.count
            if n > managed { result.insert(pid) }
        }
        return result
    }

    // MARK: Watching for a window that's on its way

    /// Apps expected to open a window soon (bundle id → until when): Shoji asked for one (Mod+Return,
    /// the launcher) or the app just launched. Many apps (kitty, Electron apps) never announce new
    /// windows, and the 2-second rescan made them wait up to 2 s at their own size before tiling.
    private var expected: [String: Date] = [:]
    private var watching = false

    /// Look for the app's new window every 50 ms until it shows up (or `seconds` pass).
    func expectWindow(of bundleID: String, for seconds: TimeInterval = 3) {
        expected[bundleID] = max(expected[bundleID] ?? .distantPast, Date().addingTimeInterval(seconds))
        if !watching {
            watching = true
            watchExpected()
        }
    }

    private func watchExpected() {
        let now = Date()
        expected = expected.filter { $0.value > now }
        guard !expected.isEmpty else { watching = false; return }
        for id in expected.keys {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                let pid = app.processIdentifier
                if appElements[pid] == nil { observe(app) } // just launched: not ready the first time(s)
                guard let el = appElements[pid] else { continue }
                // (No retries of their own: this runs again in 50 ms.)
                for e in AX.windows(ofApp: el) where lookup(e) == nil { addWindow(e, pid: pid, isNew: true, retries: false) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.watchExpected() }
    }

    /// Apps launched recently (pid → when), rescanned for a minute.
    private var recentLaunches: [pid_t: Date] = [:]

    /// What each app last reported (window count / error), so the log only notes changes.
    private var scanReports: [pid_t: String] = [:]

    /// Pick up any of an app's windows Shoji doesn't know yet.
    private func scanWindows(of pid: pid_t, appElement: AXUIElement, name: String, areNew: Bool = false) {
        let found = AX.windows(ofApp: appElement)
        let report: String
        if found.isEmpty {
            let err = AX.error(appElement, kAXWindowsAttribute).map { "AXWindows error \($0.rawValue)" } ?? "AXWindows empty"
            report = "no windows exposed (\(err))"
        } else {
            let kinds = found.map { "\(AX.string($0, kAXRoleAttribute) ?? "?")/\(AX.string($0, kAXSubroleAttribute) ?? "-")" }
            report = "\(found.count) window(s): \(kinds.joined(separator: ", "))"
        }
        if scanReports[pid] != report {
            scanReports[pid] = report
            ShojiLog.write("scan \(name): \(report)")
        }
        for e in found where lookup(e) == nil { addWindow(e, pid: pid, isNew: areNew) }
    }

    /// macOS focused a window (a click, ⌘Tab, a dock click, an app opening a window).
    private func systemFocused(_ w: ManagedWindow) {
        guard !dormant.contains(w.id) else { return }
        if w.workspace != current.index, !w.isPinned {
            // Hyprland's focus_on_activate: follow the app to its workspace.
            guard c.focusOnActivate, Date() > ignoreActivationUntil else { return }
            // But closing a window makes its app (or macOS, if the app quit) focus another window,
            // perhaps one parked on another workspace: that isn't the user asking to go there.
            // The close and the focus change arrive in either order, so decide a moment later.
            let before = focusedID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.windows[w.id] === w, !self.dormant.contains(w.id),
                      w.workspace != self.current.index, !w.isPinned,
                      Date().timeIntervalSince(self.closedHereAt) > 0.6,
                      before.map({ self.windows[$0] != nil }) ?? true else { return }
                self.switchTo(w.workspace, focusing: w)
            }
            return
        }
        setFocused(w)
    }

    /// The user dragged or resized a window (or an app resized itself).
    private func userMoved(_ w: ManagedWindow) {
        guard !w.isParked, !dormant.contains(w.id), w.workspace == current.index || w.isPinned,
              let f = w.frame else { return }
        if let e = w.expectedFrame, abs(e.minX - f.minX) < 2, abs(e.minY - f.minY) < 2,
           abs(e.width - f.width) < 2, abs(e.height - f.height) < 2 { return } // our own move
        if w.isFloating {
            if containing(w)?.fullscreen !== w { w.floatFrame = f } // fullscreen keeps the frame to return to
            return
        }
        // Only a mouse drag is the user moving or resizing a tile. Anything else is the app
        // adjusting the frame it was given (terminals round to whole character cells, others
        // restore a saved size, some enforce a minimum): never let that rewrite the layout.
        guard NSEvent.pressedMouseButtons != 0 else {
            appAdjusted(w, to: f)
            return
        }
        // Tiled: wait until the mouse is released, then turn the drag into a swap or a resize.
        settleWork.removeValue(forKey: w.id)?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle(w) }
        settleWork[w.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// An app changed its tiled window's frame by itself. Small differences (cell rounding,
    /// minimum sizes) are accepted as they are; a big jump (the app restoring an old frame) gets
    /// its tile back — but only a couple of times, so an app that insists doesn't loop forever.
    private func appAdjusted(_ w: ManagedWindow, to f: CGRect) {
        guard let e = w.expectedFrame else { return }
        let off = max(abs(e.minX - f.minX), abs(e.minY - f.minY), abs(e.width - f.width), abs(e.height - f.height))
        guard off > 40, w.reapplyCount < 2 else { return }
        w.reapplyCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.current.tree.leaf(for: w) != nil, NSEvent.pressedMouseButtons == 0 else { return }
            AX.setFrame(w.element, e)
        }
    }

    private func settle(_ w: ManagedWindow) {
        if NSEvent.pressedMouseButtons != 0 { userMoved(w); return } // still dragging
        settleWork[w.id] = nil
        guard let ws = workspaces.first(where: { $0.tree.leaf(for: w) != nil }), ws === current,
              let f = w.frame, let old = ws.tree.rect(for: w) else { return }
        if AX.bool(w.element, "AXFullScreen") == true { return }
        if abs(f.width - old.width) < 4 && abs(f.height - old.height) < 4 {
            dropTile(w, at: AX.axPoint(fromScreen: NSEvent.mouseLocation), in: ws)
        } else {
            ws.tree.adopt(w, resizedTo: f, gap: c.gapsIn * 2)
        }
        relayout(force: true)
    }

    // MARK: Layout

    func relayout(force: Bool = false) {
        let ws = current
        let a = area
        ws.tree.layout(in: a)
        let full = usableFrame
        for w in ws.tree.windows where !dormant.contains(w.id) {
            guard var r = ws.tree.rect(for: w) else { continue }
            if ws.fullscreen === w { r = ws.fullscreenMode == .full ? full : a }
            apply(r, to: w, force: force)
        }
        for w in ws.floating where !dormant.contains(w.id) {
            if ws.fullscreen === w {
                apply(ws.fullscreenMode == .full ? full : a, to: w, force: force)
            } else if w.isParked || force, let f = w.floatFrame {
                apply(f, to: w, force: true)
            }
        }
        if let fs = ws.fullscreen { AX.raise(fs.element) }
        // A tile turned out too small for a window's minimum size: move it where it fits.
        if let (w, size) = tooBig {
            tooBig = nil
            DispatchQueue.main.async { [weak self] in self?.relocate(w, minimum: size) }
        }
    }

    /// Set by `apply` when a tiled window won't shrink to its tile.
    private var tooBig: (ManagedWindow, CGSize)?

    /// Move a window whose minimum size doesn't fit its tile to a workspace where it does, and
    /// go there: first an occupied workspace where splitting a tile leaves enough room, else the
    /// first empty one (the whole screen). Too big even for that: float it.
    private func relocate(_ w: ManagedWindow, minimum: CGSize) {
        let from = current
        guard !w.relocated, from.tree.leaf(for: w) != nil, NSEvent.pressedMouseButtons == 0 else { return }
        w.relocated = true
        let a = area, gap = c.gapsIn * 2
        func fits(_ s: CGSize) -> Bool { s.width + 2 >= minimum.width && s.height + 2 >= minimum.height }
        var target: (Workspace, ManagedWindow?)?
        for ws in workspaces where ws !== from && !ws.isFloatingMode && !ws.tree.isEmpty {
            ws.tree.layout(in: a)
            // Dwindle splits the chosen tile along its longer side; the new window gets one half.
            let roomy = ws.tree.windows.compactMap { t -> (ManagedWindow, CGSize)? in
                guard let r = ws.tree.rect(for: t) else { return nil }
                let half = r.height > r.width ? CGSize(width: r.width, height: (r.height - gap) / 2)
                                              : CGSize(width: (r.width - gap) / 2, height: r.height)
                return fits(half) ? (t, half) : nil
            }.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
            if let (t, _) = roomy { target = (ws, t); break }
        }
        if target == nil, fits(a.size), let empty = workspaces.first(where: { $0 !== from && $0.isEmpty && !$0.isFloatingMode }) {
            target = (empty, nil)
        }
        guard let (ws, neighbour) = target else {
            // Doesn't fit even a whole screen: float it, centered, on screen.
            ShojiLog.write("\(w.appName) needs \(Int(minimum.width))×\(Int(minimum.height)) — more than the screen; floating it")
            from.tree.remove(w)
            w.isFloating = true
            w.floatFrame = CGRect(x: a.minX + max(0, (a.width - minimum.width) / 2), y: a.minY + max(0, (a.height - minimum.height) / 2),
                                  width: minimum.width, height: minimum.height)
            from.floating.append(w)
            relayout(force: true)
            notifyChange()
            return
        }
        ShojiLog.write("\(w.appName) needs \(Int(minimum.width))×\(Int(minimum.height)); moved to workspace \(ws.index)")
        from.remove(w)
        w.workspace = ws.index
        ws.tree.insert(w, near: neighbour)
        relayout() // re-tile what's left here, then go there
        switchTo(ws.index, focusing: w)
    }

    /// Give a window its tile. Checks the window's *actual* frame, not what Shoji last set:
    /// apps resize themselves after opening (kitty's initial_window_width/height, saved sizes),
    /// and trusting our own record left them at their own size.
    private func apply(_ r: CGRect, to w: ManagedWindow, force: Bool) {
        let r = r.integral
        let wasParked = w.isParked
        w.isParked = false
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        if !force, !wasParked, let f = w.frame {
            if near(f, r) { w.expectedFrame = r; return }
            if w.snappedFor == r, let s = w.snappedFrame, near(f, s) { return } // already settled, snapped
        }
        w.setFrame(r)
        // The window may not take the tile's size exactly:
        //  - a little smaller (Terminal.app sizes in whole character cells): center it, so the
        //    leftover is an even margin rather than a ragged edge;
        //  - bigger (the app has a minimum size and the tile is smaller): keep it fully on screen,
        //    overlapping its neighbour, instead of running off the right edge or under the Dock.
        // Either way remember the result, so later layouts don't keep re-sizing it.
        guard let f = w.frame, !near(f, r) else {
            w.snappedFor = nil
            w.snappedFrame = nil
            return
        }
        let bounds = area
        func place(_ size: CGFloat, tile: CGFloat, tileMin: CGFloat, boundsMin: CGFloat, boundsMax: CGFloat) -> CGFloat {
            if size <= tile { return size > tile - 40 ? tileMin + ((tile - size) / 2).rounded() : tileMin }
            return max(boundsMin, min(tileMin, boundsMax - size)) // too big: pull back inside the screen
        }
        let fixed = CGRect(x: place(f.width, tile: r.width, tileMin: r.minX, boundsMin: bounds.minX, boundsMax: bounds.maxX),
                           y: place(f.height, tile: r.height, tileMin: r.minY, boundsMin: bounds.minY, boundsMax: bounds.maxY),
                           width: f.width, height: f.height)
        if f.width > r.width + 2 || f.height > r.height + 2 {
            if !w.isFloating, !w.relocated, current.fullscreen !== w, current.tree.leaf(for: w) != nil, tooBig == nil {
                tooBig = (w, f.size)
            }
            ShojiLog.write("\(w.appName) has a minimum size \(Int(f.width))×\(Int(f.height)) bigger than its tile \(Int(r.width))×\(Int(r.height))")
        }
        if fixed.origin != f.origin { AX.setPosition(w.element, fixed.origin) }
        w.expectedFrame = fixed
        w.snappedFor = r
        w.snappedFrame = fixed
    }

    /// `keepFloatFrame`: the window's floating frame was just chosen (a rule, a restore) — don't
    /// replace it with where the window happens to be.
    private func park(_ w: ManagedWindow, keepFloatFrame: Bool = false) {
        guard !w.isParked else { return }
        if w.isFloating, !keepFloatFrame, let f = w.frame { w.floatFrame = f }
        w.isParked = true
        AX.setPosition(w.element, parkPoint)
    }

    // MARK: Focus

    var focused: ManagedWindow? { focusedID.flatMap { windows[$0] } }

    func focus(_ w: ManagedWindow) {
        if w.workspace != current.index, !w.isPinned {
            switchTo(w.workspace, focusing: w)
            return
        }
        AX.set(w.element, kAXMainAttribute, kCFBooleanTrue)
        AX.raise(w.element)
        if let app = appElements[w.pid] { AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue) }
        setFocused(w)
    }

    private func setFocused(_ w: ManagedWindow) {
        if focusedID != w.id { previousFocusedID = focusedID }
        focusedID = w.id
        containing(w)?.noteFocused(w)
        notifyChange()
    }

    private func notifyChange() {
        onChange?()
        scheduleSessionSave()
    }

    // MARK: Session (survive restarts)

    /// The previous run's session while the startup scan runs; nil afterwards.
    private var restoring: SessionFile?
    /// Tiled windows found during the startup scan, waiting for their workspace's tree.
    private var restoredTiled: [CGWindowID: ManagedWindow] = [:]
    private var sessionSave: DispatchWorkItem?

    /// Rebuild every workspace's layout from the session, park the windows of hidden workspaces
    /// and go back to the workspace that was current.
    private func finishRestore() {
        guard let s = restoring else { return }
        defer { restoring = nil; restoredTiled = [:] }
        var placed = 0
        for space in s.workspaces {
            guard let ws = workspace(index: space.index) else { continue }
            let mine = restoredTiled.filter { $0.value.workspace == ws.index }
            guard !mine.isEmpty else { continue }
            let others = ws.tree.windows // placed normally during the scan (not in the session)
            ws.tree.setRoot(space.tree?.build(mine))
            for w in mine.values where ws.tree.leaf(for: w) == nil { ws.tree.insert(w, near: nil) }
            for w in others where ws.tree.leaf(for: w) == nil { ws.tree.insert(w, near: nil) }
            if let f = space.focused, let w = windows[f], ws.contains(w) { ws.noteFocused(w) }
            placed += mine.count
        }
        for w in restoredTiled.values where !workspaces.contains(where: { $0.tree.leaf(for: w) != nil }) {
            place(w, in: current) // its workspace no longer exists
        }
        if let ws = workspaces.first(where: { $0.index == s.current }) { current = ws }
        for ws in workspaces where ws !== current {
            for w in ws.windows where !w.isPinned { park(w) }
        }
        ShojiLog.write("session restored: \(placed) tiled windows back in their layouts, current workspace \(s.current)")
        relayout(force: true)
        if let f = s.focused, let w = windows[f], w.workspace == current.index { focus(w) }
    }

    private func scheduleSessionSave() {
        guard restoring == nil else { return }
        sessionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveSession() {
        guard restoring == nil else { return }
        SessionFile(current: current.index, focused: focusedID,
                    pids: Dictionary(windows.values.map { (String($0.id), $0.pid) }, uniquingKeysWith: { a, _ in a }),
                    workspaces: workspaces.map { ws in
            SessionFile.Space(index: ws.index, tree: SessionFile.Node(ws.tree.root), floating: ws.floating.map { w in
                let f = (w.isParked ? w.floatFrame : (w.frame ?? w.floatFrame)) ?? .zero
                return SessionFile.Floating(id: w.id, frame: [f.minX, f.minY, f.width, f.height], pinned: w.isPinned)
            }, focused: ws.focused?.id)
        }).save()
    }

    /// Windows of the current workspace with their on-screen rects, for borders and hovering.
    func visibleWindows() -> [(ManagedWindow, CGRect)] {
        let ws = current
        if let fs = ws.fullscreen {
            return [(fs, ws.fullscreenMode == .full ? usableFrame : area)]
        }
        var list: [(ManagedWindow, CGRect)] = []
        for w in ws.tree.windows where !dormant.contains(w.id) {
            if let r = ws.tree.rect(for: w) { list.append((w, r.integral)) }
        }
        for w in ws.floating where !dormant.contains(w.id) && !w.isParked {
            if let f = w.frame ?? w.floatFrame { list.append((w, f)) }
        }
        return list
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.hover() }
        }
    }

    /// Focus follows mouse: focus the tiled window under the pointer — but only if it's the
    /// window actually on top there. A dialog, floating window or anything else in front of a tile
    /// (Finder's "Empty Trash?" alert over kitty) keeps focus; focusing the tile behind it would
    /// raise the tile and bury the dialog.
    private func hover() {
        guard c.focusFollowsMouse, NSEvent.pressedMouseButtons == 0, Date().timeIntervalSince(lastHover) > 0.05 else { return }
        lastHover = Date()
        // A floating window (System Settings, a dialog, a floating terminal) keeps focus while the
        // pointer wanders over tiles: focusing a tile raises it on macOS, which buried the floating
        // window. Click a tile (or use the keyboard) to move on.
        if let f = focused, f.isFloating, !f.isParked, !dormant.contains(f.id), f.workspace == current.index || f.isPinned {
            return
        }
        let p = AX.axPoint(fromScreen: NSEvent.mouseLocation)
        guard let id = topWindowID(at: p), id != focusedID, let w = windows[id], !w.isFloating,
              current.tree.leaf(for: w) != nil else { return }
        focus(w)
    }

    /// The frontmost normal-level window at a point (AX/CG coordinates), from the window server's
    /// front-to-back list.
    private func topWindowID(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  CGRect(x: x, y: y, width: w, height: h).contains(p) else { continue }
            if (info[kCGWindowAlpha as String] as? Double ?? 1) <= 0 { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    // MARK: Workspaces

    func switchTo(_ index: Int, focusing target: ManagedWindow? = nil) {
        guard let ws = workspaces.first(where: { $0.index == index }) else { return }
        if ws !== current {
            let old = current
            ignoreActivationUntil = Date().addingTimeInterval(0.5)
            for w in old.windows where !w.isPinned { park(w) }
            // Pinned windows come along.
            for w in old.floating where w.isPinned {
                old.floating.removeAll { $0 === w }
                ws.floating.append(w)
                w.workspace = ws.index
            }
            current = ws
            relayout()
        }
        if let w = target ?? ws.focused ?? ws.windows.last {
            focus(w)
        } else {
            focusedID = nil
        }
        notifyChange()
    }

    /// Mod+Tab: step through workspaces that have windows (plus the current one).
    func cycleWorkspaces(_ delta: Int) {
        let candidates = workspaces.filter { !$0.isEmpty || $0 === current }
        guard candidates.count > 1, let i = candidates.firstIndex(where: { $0 === current }) else { return }
        switchTo(candidates[(i + delta + candidates.count) % candidates.count].index)
    }

    func moveFocused(to index: Int, follow: Bool) {
        guard let w = focused, let from = containing(w), let target = workspaces.first(where: { $0.index == index }),
              target !== from else { return }
        if w.isFloating { w.floatFrame = w.frame ?? w.floatFrame }
        from.remove(w)
        w.isPinned = false
        place(w, in: target)
        park(w)
        relayout()
        if follow { switchTo(index, focusing: w) } else if let next = current.focused ?? current.windows.last { focus(next) }
        notifyChange()
    }

    /// A workspace by index.
    func workspace(index: Int) -> Workspace? { workspaces.first { $0.index == index } }

    /// The workspace a window is on.
    func containing(_ w: ManagedWindow) -> Workspace? { workspaces.first { $0.contains(w) } }

    // MARK: Mouse (Mod+drag, see MouseBinds)

    /// The managed window on top at a point (AX coordinates), if it's on screen.
    func managedWindow(at p: CGPoint) -> ManagedWindow? {
        guard let id = topWindowID(at: p), let w = windows[id], !w.isParked, !dormant.contains(id) else { return nil }
        return w
    }

    /// Where a tiled window's tile is.
    func tileRect(of w: ManagedWindow) -> CGRect? { containing(w)?.tree.rect(for: w) }

    /// Mod+drag of a floating window (move or resize).
    func mouseSetFloatingFrame(_ w: ManagedWindow, _ f: CGRect) {
        w.floatFrame = f
        w.setFrame(f)
    }

    /// Mod+drag of a tiled window: it follows the pointer; dropping it swaps (`mouseDropTiled`).
    func mouseMoveTiled(_ w: ManagedWindow, origin: CGPoint) {
        guard let size = w.expectedFrame?.size ?? w.frame?.size else { return }
        w.expectedFrame = CGRect(origin: origin, size: size).integral
        AX.setPosition(w.element, origin)
        AX.raise(w.element)
    }

    /// A tiled window dropped at a point (title-bar drag or Mod+drag): swap with the tile under the
    /// pointer; anywhere else it snaps back on the next layout.
    private func dropTile(_ w: ManagedWindow, at p: CGPoint, in ws: Workspace) {
        if let target = ws.tree.windows.first(where: { $0 !== w && (ws.tree.rect(for: $0)?.contains(p) ?? false) }) {
            ws.tree.swap(w, target)
        }
    }

    func isFullscreen(_ w: ManagedWindow) -> Bool { containing(w)?.fullscreen === w }

    func mouseDropTiled(_ w: ManagedWindow, at p: CGPoint) {
        guard let ws = containing(w) else { return }
        dropTile(w, at: p, in: ws)
        relayout(force: true)
        notifyChange()
    }

    /// Mod+right-drag of a tiled window: its edges move the split borders, live.
    func mouseResizeTiled(_ w: ManagedWindow, to rect: CGRect) {
        guard let ws = containing(w), ws.tree.leaf(for: w) != nil else { return }
        ws.tree.adopt(w, resizedTo: rect, gap: c.gapsIn * 2)
        relayout()
    }

    func mouseDragEnded() { notifyChange() }

    /// For the bar.
    var workspaceStates: [(index: Int, occupied: Bool, active: Bool)] {
        let highest = max(c.minVisibleWorkspaces, workspaces.filter { !$0.isEmpty || $0 === current }.map(\.index).max() ?? 1)
        return workspaces.filter { $0.index <= highest }.map { ($0.index, !$0.isEmpty, $0 === current) }
    }

    var hasWindows: Bool { !windows.isEmpty }

    /// Every managed window (for Stats), minimized/hidden ones excluded.
    var allWindows: [ManagedWindow] { windows.values.filter { !dormant.contains($0.id) } }

    func windows(ofPID pid: pid_t) -> [ManagedWindow] { windows.values.filter { $0.pid == pid } }

    /// Dock click: the app's most recent window, wherever it is.
    func focusApp(pid: pid_t) -> Bool {
        let mine = windows(ofPID: pid).filter { !dormant.contains($0.id) }
        guard !mine.isEmpty else { return false }
        let recent = current.windows.filter { $0.pid == pid }.last
            ?? workspaces.lazy.compactMap { ws in ws.focused.flatMap { $0.pid == pid ? $0 : nil } }.first
            ?? mine[0]
        focus(recent)
        return true
    }

    // MARK: Commands

    func focus(_ d: Direction) {
        guard let w = focused else { if let any = current.windows.last { focus(any) }; return }
        let candidates = visibleWindows().filter { $0.0 !== w }
        let from = visibleWindows().first { $0.0 === w }?.1 ?? w.frame ?? .zero
        if let next = LayoutTree.nearest(from: from, among: candidates, d, overlapping: w.isFloating) { focus(next) }
    }

    func swap(_ d: Direction) {
        guard let w = focused else { return }
        if w.isFloating { nudge(w, move: d); return }
        if let other = current.tree.neighbor(of: w, d) {
            current.tree.swap(w, other)
            relayout()
        }
    }

    func resize(_ d: Direction) {
        guard let w = focused else { return }
        if w.isFloating { nudge(w, resize: d); return }
        current.tree.resize(w, direction: d)
        relayout()
    }

    private func nudge(_ w: ManagedWindow, move: Direction? = nil, resize: Direction? = nil) {
        guard var f = w.frame else { return }
        let step: CGFloat = 40
        switch move {
        case .left: f.origin.x -= step
        case .right: f.origin.x += step
        case .up: f.origin.y -= step
        case .down: f.origin.y += step
        case nil: break
        }
        switch resize {
        case .left: f.size.width = max(200, f.width - step)
        case .right: f.size.width += step
        case .up: f.size.height = max(120, f.height - step)
        case .down: f.size.height += step
        case nil: break
        }
        w.floatFrame = f
        w.setFrame(f)
    }

    func toggleSplit() {
        guard let w = focused, !w.isFloating else { return }
        current.tree.toggleSplit(of: w)
        relayout()
    }

    func toggleFullscreen(_ mode: Workspace.Fullscreen) {
        guard let w = focused else { return }
        let ws = current
        if ws.fullscreen === w && ws.fullscreenMode == mode {
            ws.fullscreen = nil
            if w.isFloating, let f = w.floatFrame { w.setFrame(f) }
        } else {
            if w.isFloating, ws.fullscreen !== w { w.floatFrame = w.frame ?? w.floatFrame }
            ws.fullscreen = w
            ws.fullscreenMode = mode
        }
        relayout(force: true)
        notifyChange()
    }

    func toggleFloating() {
        guard let w = focused else { return }
        let ws = current
        if ws.fullscreen === w { ws.fullscreen = nil }
        if w.isFloating {
            ws.floating.removeAll { $0 === w }
            w.isFloating = false
            w.isPinned = false
            ws.tree.insert(w, near: ws.history.reversed().first { !$0.isFloating && $0 !== w && ws.contains($0) })
        } else {
            ws.tree.remove(w)
            w.isFloating = true
            let a = area
            let size = CGSize(width: min(a.width * 0.6, 1100), height: min(a.height * 0.65, 760))
            w.floatFrame = CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
            ws.floating.append(w)
            w.setFrame(w.floatFrame!)
            AX.raise(w.element)
        }
        relayout()
        notifyChange()
    }

    func centerFloating() {
        guard let w = focused, w.isFloating, let f = w.frame else { return }
        let a = area
        let r = CGRect(x: a.midX - f.width / 2, y: a.midY - f.height / 2, width: f.width, height: f.height)
        w.floatFrame = r
        w.setFrame(r)
    }

    /// Hyprland's pin: a floating window that stays on screen across workspaces.
    func togglePin() {
        guard let w = focused else { return }
        if !w.isFloating { toggleFloating() }
        w.isPinned.toggle()
        notifyChange()
    }

    func closeFocused() {
        guard let w = focused else { return }
        if w.pid == getpid(), let own = NSApp.window(withWindowNumber: Int(w.id)) {
            own.performClose(nil)
            return
        }
        if AX.close(w.element) { return }
        // No close button (title bar hidden): make sure it's the app's front window, then ⌘W.
        focus(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Programs.postCommandKey(kVK_ANSI_W, to: w.pid) }
    }

    /// A Shoji panel (launcher, help) was dismissed: Shoji was active while it showed, so give the
    /// keyboard back to the window that had it.
    func refocusAfterPanel() {
        guard let w = focused ?? current.focused, current.contains(w) || w.isPinned else { return }
        focus(w)
    }

    func focusPreviousWindow() {
        guard let id = previousFocusedID, let w = windows[id] else { return }
        focus(w)
    }

    /// Cycle through the current workspace's windows (raising each).
    func cycleWindows() {
        let list = current.windows.filter { !dormant.contains($0.id) }
        guard list.count > 1 else { return }
        let i = list.firstIndex { $0.id == focusedID } ?? -1
        focus(list[(i + 1) % list.count])
    }

    /// Shoji is about to open a new window of a running app (Mod+Return…): activating the app makes
    /// macOS focus one of its existing windows — possibly parked on another workspace — and
    /// following that would take the user away, so the new window opened there instead of here.
    func holdWorkspace(for seconds: TimeInterval = 1.5) {
        ignoreActivationUntil = max(ignoreActivationUntil, Date().addingTimeInterval(seconds))
    }

    /// The next window this app opens floats, centered (Mod+Shift+Return).
    func floatNextWindow(of bundleID: String) {
        pendingFloat = (bundleID, Date().addingTimeInterval(5))
    }

    // MARK: Settings and shutdown

    private func configChanged() {
        // Workspaces switched between tiled and floating in Settings.
        for ws in workspaces {
            if ws.isFloatingMode {
                for w in ws.tree.windows {
                    // Its tile, else where it is on screen — but a parked (hidden-workspace) window's
                    // frame is the park point: give it a centred frame instead.
                    let a = area
                    let fallback = CGRect(x: a.midX - a.width * 0.3, y: a.midY - a.height * 0.3,
                                          width: a.width * 0.6, height: a.height * 0.6)
                    w.floatFrame = ws.tree.rect(for: w) ?? (w.isParked ? nil : w.frame) ?? fallback
                    ws.tree.remove(w)
                    w.isFloating = true
                    ws.floating.append(w)
                }
            }
        }
        relayout(force: true)
        notifyChange()
    }

    /// Before quitting: bring every parked window back on screen, so nothing is lost.
    func restoreAllWindows() {
        sessionSave?.cancel()
        saveSession() // before parked windows are brought back on screen
        let a = area
        var offset: CGFloat = 0
        for w in windows.values where w.isParked {
            let size = w.floatFrame?.size ?? w.expectedFrame?.size ?? CGSize(width: 900, height: 600)
            AX.setFrame(w.element, CGRect(x: a.minX + offset, y: a.minY + offset, width: size.width, height: size.height))
            w.isParked = false
            offset = (offset + 32).truncatingRemainder(dividingBy: 320)
        }
    }
}
