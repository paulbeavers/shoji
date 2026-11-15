import AppKit

/// A small preview of a theme, drawn in that theme's own colours.
final class ThemeSwatchView: NSView {
    var theme: LucentTheme? { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var showsName = true
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = theme else { return }
        let p = t.palette
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let card = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        p.base.setFill()
        card.fill()
        // Focused-window look for the current theme, a quiet outline otherwise.
        if isCurrent {
            card.lineWidth = 2.5
            NSGradient(colors: [p.mauve, p.blue])?.draw(in: NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9), angle: 45)
            p.base.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 2.5, dy: 2.5), xRadius: 7, yRadius: 7).fill()
        } else {
            (isHighlighted ? p.overlay : p.surface0).setStroke()
            card.lineWidth = 1
            card.stroke()
        }
        var y: CGFloat = 10
        if showsName {
            let name = NSAttributedString(string: t.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: p.text])
            let mode = NSAttributedString(string: t.isLight ? "light" : "dark", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: p.overlay])
            let modeW = mode.size().width
            name.draw(with: CGRect(x: 12, y: y, width: bounds.width - 30 - modeW, height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            mode.draw(at: CGPoint(x: bounds.width - 12 - modeW, y: y + 2))
            y += 24
        } else {
            y = (bounds.height - 12) / 2
        }
        // Accent swatches, in Lucent's role order.
        let swatches = [p.mauve, p.blue, p.sapphire, p.teal, p.green, p.yellow, p.peach, p.red, p.pink]
        let d: CGFloat = 12, gap: CGFloat = 5
        var x: CGFloat = 12
        for c in swatches where x + d <= bounds.width - 10 {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: d, height: d)).fill()
            x += d + gap
        }
        // Text-on-surface sample, so contrast is visible at a glance.
        if showsName, x + 34 <= bounds.width - 10 {
            let sample = NSBezierPath(roundedRect: CGRect(x: bounds.width - 46, y: y - 2, width: 34, height: 16), xRadius: 4, yRadius: 4)
            p.surface0.setFill()
            sample.fill()
            NSAttributedString(string: "Aa", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                          .foregroundColor: p.text])
                .draw(at: CGPoint(x: bounds.width - 37, y: y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Settings → Theme: a grid of cards; clicking one switches theme immediately.
final class ThemeGridView: NSView {
    private var cards: [ThemeSwatchView] = []
    private let cardHeight: CGFloat = 62
    private let gap: CGFloat = 10

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for t in ThemeLibrary.all() {
            let card = ThemeSwatchView()
            card.theme = t
            card.isCurrent = t.id == Config.shared.themeID
            card.onClick = { Config.shared.selectTheme(t.id) }
            cards.append(card)
            addSubview(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func columns(for width: CGFloat) -> Int { max(1, Int((width + gap) / (190 + gap))) }

    func height(for width: CGFloat) -> CGFloat {
        let rows = (cards.count + columns(for: width) - 1) / columns(for: width)
        return CGFloat(rows) * (cardHeight + gap)
    }

    override func layout() {
        super.layout()
        let cols = columns(for: bounds.width)
        let w = (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, card) in cards.enumerated() {
            card.frame = CGRect(x: CGFloat(i % cols) * (w + gap), y: CGFloat(i / cols) * (cardHeight + gap),
                                width: w, height: cardHeight)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
