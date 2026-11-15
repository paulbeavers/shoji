import AppKit

/// `--preview out.png`: render the menu bar pills and sample tiles offscreen — for checking the
/// look without running the window manager (no permissions, no system changes).
@MainActor
enum Preview {
    static func render(to path: String) {
        let c = Config.shared
        let size = CGSize(width: 1440, height: 400)
        let root = FlippedView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = c.mantle.cgColor

        // A strip like the macOS menu bar, with Shoji's workspace pills at the right.
        let menuBarH: CGFloat = 24
        let strip = NSView(frame: CGRect(x: 0, y: 0, width: size.width, height: menuBarH))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        root.addSubview(strip)
        var ranges: [(index: Int, minX: CGFloat, maxX: CGFloat)] = []
        var width: CGFloat = 0
        let pills = WorkspaceMenu.image(for: [(1, true, false), (2, true, true), (3, false, false), (4, true, false), (5, false, false)],
                                        ranges: &ranges, width: &width)
        let pillView = NSImageView(frame: CGRect(x: size.width - width - 220, y: 1, width: width, height: 22))
        pillView.image = pills
        pillView.appearance = NSAppearance(named: .darkAqua)
        strip.addSubview(pillView)

        // Two tiled "windows" below the bar, inside the gaps.
        let gap = c.gapsIn * 2, top = menuBarH + c.gapsOut, h: CGFloat = 200
        let w1 = CGRect(x: c.gapsOut, y: top, width: (size.width - 2 * c.gapsOut - gap) * 0.55, height: h)
        let w2 = CGRect(x: w1.maxX + gap, y: top, width: size.width - c.gapsOut - w1.maxX - gap, height: h)
        for r in [w1, w2] {
            let win = CALayer()
            win.frame = r
            win.backgroundColor = c.base.cgColor
            win.cornerRadius = 12
            win.borderWidth = 1
            win.borderColor = c.surface0.cgColor
            root.layer?.addSublayer(win)
        }

        root.layoutSubtreeIfNeeded()
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// The app icon: three shoji panes with the active one in Lucent's gradient.
@MainActor
enum AppIcon {
    static func render(to path: String) {
        let s: CGFloat = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let card = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSColor(hex: 0x11111B).setFill()
        card.fill()
        let panes = [CGRect(x: 190, y: 190, width: 370, height: 644),
                     CGRect(x: 600, y: 532, width: 234, height: 302),
                     CGRect(x: 600, y: 190, width: 234, height: 302)]
        for (i, r) in panes.enumerated() {
            let p = NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36)
            NSColor(hex: 0x1E1E2E).setFill()
            p.fill()
            p.lineWidth = 22
            if i == 0 {
                NSGradient(colors: [NSColor(hex: 0xCBA6F7), NSColor(hex: 0x89B4FA)])?.draw(in: p.copy() as! NSBezierPath, angle: -45)
                NSColor(hex: 0x1E1E2E).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 16, dy: 16), xRadius: 24, yRadius: 24).fill()
            } else {
                NSColor(hex: 0x45475A).setStroke()
                p.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
