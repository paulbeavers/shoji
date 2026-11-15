import AppKit

/// One of Shoji's virtual workspaces (like AeroSpace, not macOS Spaces: windows of hidden
/// workspaces are parked off-screen, so switching is instant and needs no private Spaces APIs).
@MainActor
final class Workspace {
    enum Fullscreen { case full, maximized }

    let index: Int
    let tree = LayoutTree()
    /// Floating windows on this workspace (pinned ones travel with the current workspace).
    var floating: [ManagedWindow] = []
    /// Focus history, most recent last.
    private(set) var history: [ManagedWindow] = []
    var fullscreen: ManagedWindow?
    var fullscreenMode: Fullscreen = .full

    init(index: Int) { self.index = index }

    /// Floating by Settings, or by a `workspace = N, floating` line in shoji.conf.
    var isFloatingMode: Bool {
        Config.shared.floatingWorkspaces.contains(index) || UserConfig.shared.floatingWorkspaces.contains(index)
    }
    var windows: [ManagedWindow] { tree.windows + floating }
    var isEmpty: Bool { windows.isEmpty }
    var focused: ManagedWindow? { history.last { w in windows.contains { $0 === w } } }

    func contains(_ w: ManagedWindow) -> Bool { windows.contains { $0 === w } }

    func noteFocused(_ w: ManagedWindow) {
        history.removeAll { $0 === w }
        history.append(w)
        if history.count > 50 { history.removeFirst() }
    }

    /// Take a window off this workspace (tree, floating list, history, fullscreen).
    func remove(_ w: ManagedWindow) {
        tree.remove(w)
        floating.removeAll { $0 === w }
        history.removeAll { $0 === w }
        if fullscreen === w { fullscreen = nil }
    }
}
