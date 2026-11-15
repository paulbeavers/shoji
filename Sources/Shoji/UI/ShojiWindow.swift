import AppKit

/// Shoji's own windows (Settings, Stats). Shoji is an accessory app with no menu bar, so ⌘W and
/// Esc are handled here; and they follow Settings → Windows like kitty and the companion apps.
final class ShojiWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) } // Esc

    /// Settings → Windows: translucent by `windowOpacity` (painted on `background`), and no title
    /// bar or buttons with `hideTitleBars` (still resizable, movable by its background).
    @MainActor func applyWindowSettings(background: NSView) {
        let c = Config.shared
        isOpaque = false
        backgroundColor = .clear
        background.wantsLayer = true
        background.layer?.backgroundColor = c.mantle.withAlphaComponent(CGFloat(c.windowOpacity)).cgColor
        let hide = c.hideTitleBars
        if hide { styleMask.insert(.fullSizeContentView) } else { styleMask.remove(.fullSizeContentView) }
        titlebarAppearsTransparent = hide
        titleVisibility = hide ? .hidden : .visible
        isMovableByWindowBackground = hide
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = hide
        }
        contentView?.needsLayout = true
    }

    /// How far the content view reaches under the (hidden, transparent) title bar: lay content out
    /// below it — that strip drags the window, so a control there can't be clicked. 0 when shown.
    @MainActor var titlebarInset: CGFloat {
        guard styleMask.contains(.fullSizeContentView) else { return 0 }
        return max(0, frame.height - contentLayoutRect.height)
    }
}
