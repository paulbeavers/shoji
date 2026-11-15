import Foundation

/// ~/Library/Logs/Shoji/shoji.log: which windows Shoji tiles, floats or ignores, and why — for
/// apps that don't tile as expected. Trimmed to the last ~500 KB at launch.
enum ShojiLog {
    private static let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Shoji")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shoji.log")
    }()
    private static let handle: FileHandle? = {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 500_000,
           let data = fm.contents(atPath: url.path) {
            try? data.suffix(200_000).write(to: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = FileHandle(forWritingAtPath: url.path)
        h?.seekToEndOfFile()
        return h
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Lines already written this run: periodic rescans would otherwise repeat the same verdict.
    nonisolated(unsafe) private static var seen = Set<String>()

    static func write(_ line: String) {
        guard seen.insert(line).inserted else { return }
        if seen.count > 2000 { seen.removeAll() }
        handle?.write(Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }
}
