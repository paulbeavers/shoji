import AppKit
import ApplicationServices

/// The window server id behind an Accessibility window element (private, stable for years; used
/// by every macOS tiling manager — there is no public equivalent).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin wrappers over the Accessibility API. Coordinates are AX/Quartz global coordinates: origin
/// at the top-left of the primary display, y growing down.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system's "allow Accessibility" prompt (once per launch).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }
    static func bool(_ e: AXUIElement, _ attr: String) -> Bool? { (value(e, attr) as? NSNumber)?.boolValue }

    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(e, attr) as? [AnyObject])?.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        } ?? []
    }

    /// An app's windows, looked for everywhere they may be: some toolkits leave `AXWindows` empty
    /// but list windows among the app's children, or only as its focused/main window.
    static func windows(ofApp app: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        func add(_ e: AXUIElement) {
            if !found.contains(where: { CFEqual($0, e) }) { found.append(e) }
        }
        elements(app, kAXWindowsAttribute).forEach(add)
        elements(app, kAXChildrenAttribute).filter { string($0, kAXRoleAttribute) == kAXWindowRole as String }.forEach(add)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let e = element(app, attr) { add(e) }
        }
        return found
    }

    /// The AX error for reading an attribute (for the log), or nil if it worked.
    static func error(_ e: AXUIElement, _ attr: String) -> AXError? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return err == .success ? nil : err
    }

    static func isSettable(_ e: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, attr as CFString, &settable) == .success && settable.boolValue
    }

    static func set(_ e: AXUIElement, _ attr: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(e, attr as CFString, value)
    }

    // MARK: Geometry

    static func position(_ e: AXUIElement) -> CGPoint? {
        guard let v = value(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ e: AXUIElement) -> CGSize? {
        guard let v = value(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = position(e), let s = size(e) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setPosition(_ e: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { set(e, kAXPositionAttribute, v) }
    }

    static func setSize(_ e: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { set(e, kAXSizeAttribute, v) }
    }

    /// Size, then position, then size again: moving first can clamp the size against the screen
    /// edge, and some apps only accept a size once they're in place.
    static func setFrame(_ e: AXUIElement, _ r: CGRect) {
        setSize(e, r.size)
        setPosition(e, r.origin)
        setSize(e, r.size)
    }

    static func windowID(_ e: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
    }

    // MARK: Actions

    static func raise(_ e: AXUIElement) {
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
    }

    /// Press the window's close button (what clicking the red button does). False when it has
    /// none (e.g. kitty with its title bar hidden).
    @discardableResult
    static func close(_ e: AXUIElement) -> Bool {
        guard let button = element(e, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: Coordinates

    /// Height of the primary display, for converting between AppKit (y up) and AX (y down).
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// An AppKit screen rect in AX coordinates.
    @MainActor static func axRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// An AX rect in AppKit screen coordinates.
    @MainActor static func screenRect(fromAX r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @MainActor static func axPoint(fromScreen p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// A real app window that Shoji manages.
@MainActor
final class ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let bundleID: String?
    let appName: String
    var workspace: Int
    var isFloating: Bool
    /// Visible on every workspace (Hyprland's `pin`; floating only).
    var isPinned = false
    /// Where a floating window sits on its workspace (AX coordinates).
    var floatFrame: CGRect?
    /// The frame Shoji last gave it, to tell our own moves from the user's.
    var expectedFrame: CGRect?
    /// Parked off-screen because its workspace isn't shown.
    var isParked = false
    /// Already moved once to a workspace where it fits (never bounced around twice).
    var relocated = false

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, workspace: Int, floating: Bool) {
        self.id = id
        self.pid = pid
        self.element = element
        self.workspace = workspace
        isFloating = floating
        let app = NSRunningApplication(processIdentifier: pid)
        bundleID = app?.bundleIdentifier
        appName = app?.localizedName ?? "?"
    }

    var title: String { AX.string(element, kAXTitleAttribute) ?? "" }
    var frame: CGRect? { AX.frame(element) }
    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    /// For apps that size in steps (Terminal.app snaps to whole character cells): the tile we last
    /// asked for, and the snapped frame we settled on for it (centered in the tile).
    var snappedFor: CGRect?
    var snappedFrame: CGRect?

    /// How often Shoji has put this window back after the app moved it itself (reset per layout).
    var reapplyCount = 0

    func setFrame(_ r: CGRect) {
        let r = r.integral
        if r != expectedFrame { reapplyCount = 0 }
        expectedFrame = r
        AX.setFrame(element, r)
    }
}
