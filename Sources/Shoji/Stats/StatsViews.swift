import AppKit

// MARK: - Components

/// Label, headline value, detail line, and a sparkline or meter.
final class StatTile: NSView {
    let sparkline = SparklineView()
    let meter = MeterView()
    var showsMeter = false { didSet { meter.isHidden = !showsMeter; needsLayout = true } }
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "–")
    private let detail = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(label text: String) {
        super.init(frame: .zero)
        let c = Config.shared
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        label.stringValue = text
        label.font = c.uiFont(11.5, weight: .medium)
        value.font = c.uiFont(22, weight: .semibold)
        detail.font = c.uiFont(11, weight: .regular)
        refreshColors()
        detail.lineBreakMode = .byTruncatingTail
        meter.isHidden = true
        [label, value, detail, sparkline, meter].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshColors() {
        let c = Config.shared
        // Clear with an outline: the window already paints the translucent background (a second
        // translucent fill would double it and the tiles would look opaque).
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = c.surface0.cgColor
        label.textColor = c.subtext
        value.textColor = c.text
        detail.textColor = c.overlay0
        sparkline.refreshColors()
        meter.needsDisplay = true
    }

    func set(value v: String, detail d: String, series: [Double]) {
        value.stringValue = v
        detail.stringValue = d
        sparkline.values = series
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let w = bounds.width - 2 * pad
        label.frame = CGRect(x: pad, y: 12, width: w, height: 15)
        value.sizeToFit()
        value.frame = CGRect(x: pad, y: 28, width: w, height: value.frame.height)
        detail.frame = CGRect(x: pad, y: 58, width: w, height: 15)
        sparkline.frame = CGRect(x: pad, y: 78, width: w, height: 24)
        meter.frame = CGRect(x: pad, y: 86, width: w, height: 8)
    }
}

/// Single-series trend line: muted 2px line, faint area, latest point in the accent,
/// and a hover readout of the value under the pointer.
final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var minimumCeiling: Double = 1
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    private var hoverIndex: Int?
    private let readout = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        readout.font = Config.shared.monoUIFont(10, weight: .medium)
        readout.textColor = Config.shared.text
        readout.drawsBackground = true
        readout.backgroundColor = Config.shared.crust
        readout.isHidden = true
        addSubview(readout)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshColors() {
        readout.textColor = Config.shared.text
        readout.backgroundColor = Config.shared.crust
        needsDisplay = true
    }

    /// Points span the full history width so the line grows in from the left at first.
    private func point(_ i: Int, _ v: Double, ceiling: Double) -> CGPoint {
        let n = max(AppsSampler.historyLength - 1, 1)
        let offset = AppsSampler.historyLength - values.count
        let x = CGFloat(i + offset) / CGFloat(n) * (bounds.width - 4) + 2
        let y = bounds.height - 2 - CGFloat(v / ceiling) * (bounds.height - 4)
        return CGPoint(x: x, y: y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard values.count >= 2 else { return }
        let c = Config.shared
        let ceiling = max(minimumCeiling, (values.max() ?? 0) * 1.15)
        let pts = values.enumerated().map { point($0.offset, $0.element, ceiling: ceiling) }

        let area = NSBezierPath()
        area.move(to: CGPoint(x: pts[0].x, y: bounds.height))
        pts.forEach { area.line(to: $0) }
        area.line(to: CGPoint(x: pts.last!.x, y: bounds.height))
        area.close()
        c.accent.withAlphaComponent(0.10).setFill()
        area.fill()

        let line = NSBezierPath()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: pts[0])
        pts.dropFirst().forEach { line.line(to: $0) }
        c.overlay0.setStroke()
        line.stroke()

        // Current value in the accent.
        let last = pts.last!
        c.accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()

        if let i = hoverIndex, values.indices.contains(i) {
            let p = pts[i]
            c.surface1.setStroke()
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: p.x, y: 0))
            guide.line(to: CGPoint(x: p.x, y: bounds.height))
            guide.lineWidth = 1
            guide.stroke()
            c.text.setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard values.count >= 2 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let n = max(AppsSampler.historyLength - 1, 1)
        let offset = AppsSampler.historyLength - values.count
        let i = Int((x - 2) / max(1, bounds.width - 4) * CGFloat(n) + 0.5) - offset
        hoverIndex = min(max(0, i), values.count - 1)
        let secondsAgo = values.count - 1 - hoverIndex!
        readout.stringValue = " \(format(values[hoverIndex!]))\(secondsAgo > 0 ? " · \(secondsAgo)s ago" : " · now") "
        readout.sizeToFit()
        let px = point(hoverIndex!, values[hoverIndex!], ceiling: 1).x
        readout.frame.origin = CGPoint(x: min(max(0, px - readout.frame.width / 2), bounds.width - readout.frame.width), y: -18)
        readout.isHidden = false
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        readout.isHidden = true
        needsDisplay = true
    }
}

/// 8px usage bar; the fill carries severity (accent → warning → critical).
final class MeterView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        let r = bounds.height / 2
        let fill: NSColor = fraction >= 0.9 ? c.red : (fraction >= 0.75 ? c.yellow : c.accent)
        fill.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(bounds.height, bounds.width * CGFloat(min(1, max(0, fraction))))
        fill.setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

/// A titled table of text rows with right-aligned numeric columns.
final class InfoTable: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var columns: [String] = []
    private var rows: [[String]] = []
    private var numeric: Set<Int> = []
    private var headerless = false
    private var emptyText = ""
    private let rowHeight: CGFloat = 26

    override var isFlipped: Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = Config.shared.uiFont(14, weight: .semibold)
        titleLabel.textColor = Config.shared.text
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshColors() {
        titleLabel.textColor = Config.shared.text
        needsDisplay = true
    }

    var preferredHeight: CGFloat {
        28 + (headerless ? 0 : rowHeight) + CGFloat(max(rows.count, 1)) * rowHeight + 4
    }

    func set(columns: [String], rows: [[String]], numeric: Set<Int> = [], headerless: Bool = false, empty: String = "") {
        self.columns = columns
        self.rows = rows
        self.numeric = numeric
        self.headerless = headerless
        self.emptyText = empty
        needsDisplay = true
    }

    /// Column widths: numeric columns get a fixed width; text columns share the rest.
    private func columnRects() -> [(CGFloat, CGFloat)] {
        let numW: CGFloat = 92
        let textCols = columns.indices.filter { !numeric.contains($0) }
        let textW = (bounds.width - CGFloat(numeric.count) * numW) / CGFloat(max(textCols.count, 1))
        var x: CGFloat = 0
        var out: [(CGFloat, CGFloat)] = []
        for i in columns.indices {
            var w = numeric.contains(i) ? numW : textW
            if headerless && columns.count == 2 { w = i == 0 ? bounds.width * 0.38 : bounds.width * 0.62 }
            out.append((x, w))
            x += w
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Config.shared
        titleLabel.sizeToFit()
        titleLabel.frame.origin = .zero
        let rects = columnRects()
        var y: CGFloat = 28
        let para = { (align: NSTextAlignment) -> NSParagraphStyle in
            let p = NSMutableParagraphStyle()
            p.alignment = align
            p.lineBreakMode = .byTruncatingMiddle
            return p
        }
        func text(_ s: String, _ col: Int, _ y: CGFloat, color: NSColor, font: NSFont) {
            guard rects.indices.contains(col) else { return }
            let (x, w) = rects[col]
            let align: NSTextAlignment = numeric.contains(col) ? .right : .left
            let inset: CGFloat = 10
            (s as NSString).draw(in: CGRect(x: x + inset, y: y + 5, width: max(0, w - 2 * inset), height: rowHeight - 6),
                                 withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para(align)])
        }
        if !headerless {
            for (i, h) in columns.enumerated() { text(h, i, y, color: c.overlay0, font: c.uiFont(11, weight: .medium)) }
            y += rowHeight
            c.surface0.setFill()
            NSRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
        }
        if rows.isEmpty {
            (emptyText as NSString).draw(at: CGPoint(x: 10, y: y + 5),
                                         withAttributes: [.font: c.uiFont(12, weight: .regular), .foregroundColor: c.overlay0])
            return
        }
        for (r, row) in rows.enumerated() {
            if r % 2 == 1 {
                c.base.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: rowHeight), xRadius: 6, yRadius: 6).fill()
            }
            for (i, cell) in row.enumerated() where i < rects.count {
                let isKey = headerless && i == 0
                text(cell, i, y, color: isKey ? c.subtext : c.text,
                     font: numeric.contains(i) ? c.monoUIFont(12, weight: .regular) : c.uiFont(12.5, weight: .regular))
            }
            y += rowHeight
        }
    }
}
