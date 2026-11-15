import Foundation

/// Which window was where, so a Shoji restart puts every window back on its workspace, in its
/// place in the layout (~/.config/shoji/session.json). Windows are matched by window-server id,
/// which stays the same while the app keeps running — the case for a Shoji restart. Windows of
/// apps that restarted get new ids and are tiled normally.
struct SessionFile: Codable {
    struct Floating: Codable {
        let id: UInt32
        let frame: [Double]   // x, y, w, h (AX coordinates)
        let pinned: Bool
    }
    final class Node: Codable {
        let id: UInt32?        // leaf
        let stacked: Bool
        let ratio: Double
        let first: Node?
        let second: Node?
        init(id: UInt32?, stacked: Bool, ratio: Double, first: Node?, second: Node?) {
            self.id = id; self.stacked = stacked; self.ratio = ratio; self.first = first; self.second = second
        }
    }
    struct Space: Codable {
        let index: Int
        let tree: Node?
        let floating: [Floating]
        let focused: UInt32?
    }
    var current: Int
    var focused: UInt32?
    var workspaces: [Space]

    static var url: URL { Config.directory.appendingPathComponent("session.json") }

    static func load() -> SessionFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionFile.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Where a window was: its workspace and whether it floated (with its frame and pin).
    func placement(of id: UInt32) -> (workspace: Int, floating: Floating?)? {
        for ws in workspaces {
            if let f = ws.floating.first(where: { $0.id == id }) { return (ws.index, f) }
            if ws.tree?.contains(id) == true { return (ws.index, nil) }
        }
        return nil
    }
}

extension SessionFile.Node {
    func contains(_ id: UInt32) -> Bool {
        self.id == id || first?.contains(id) == true || second?.contains(id) == true
    }

    @MainActor convenience init?(_ node: LayoutNode?) {
        guard let node else { return nil }
        if let w = node.window {
            self.init(id: w.id, stacked: false, ratio: 0.5, first: nil, second: nil)
        } else {
            self.init(id: nil, stacked: node.stacked, ratio: Double(node.ratio),
                      first: SessionFile.Node(node.first), second: SessionFile.Node(node.second))
        }
    }

    /// Rebuild a layout subtree from the windows that still exist; splits that lost a side
    /// collapse into the other.
    @MainActor func build(_ windows: [CGWindowIDKey: ManagedWindow]) -> LayoutNode? {
        if let id {
            return windows[id].map { LayoutNode(window: $0) }
        }
        let a = first?.build(windows), b = second?.build(windows)
        guard let a, let b else { return a ?? b }
        let n = LayoutNode()
        n.stacked = stacked
        n.ratio = CGFloat(ratio)
        n.first = a
        n.second = b
        a.parent = n
        b.parent = n
        return n
    }
}

typealias CGWindowIDKey = UInt32
