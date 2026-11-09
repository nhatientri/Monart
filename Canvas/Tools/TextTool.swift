import AppKit

/// Click to place a text field (shown by the canvas view); committing rasterizes the
/// text into the active layer as one undo step.
final class TextTool: Tool {
    var cursor: NSCursor { .iBeam }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        context.host?.beginTextEntry(at: event.location)
        return .null
    }

    /// The editor's font. `scale` lets the on-screen text field match the canvas zoom.
    static func font(for editor: EditorState, scale: CGFloat = 1) -> NSFont {
        let size = max(1, editor.fontSize * scale)
        return NSFontManager.shared.font(withFamily: editor.fontFamily, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }

    /// Draws `text` with its top-left at `origin` (canvas pixels). Returns the dirty rect.
    @discardableResult
    static func rasterize(_ text: String, at origin: CGPoint, font: NSFont, color: CGColor,
                          into layer: Layer, history: HistoryManager, clip: Selection? = nil) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .black,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()

        history.beginEdit(on: layer)
        layer.bitmap.context.saveGState()
        clip?.clip(layer.bitmap.context)
        NSGraphicsContext.saveGraphicsState()
        // The bitmap's CTM is already y-down; telling AppKit it's flipped keeps glyphs upright.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: layer.bitmap.context, flipped: true)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        layer.bitmap.context.restoreGState()

        // Glyphs (italics, descenders) can overhang the typographic box a little.
        let overhang = font.pointSize * 0.25 + 2
        let dirty = CGRect(origin: origin, size: size)
            .insetBy(dx: -overhang, dy: -overhang)
            .pixelAligned(clampedTo: layer.bitmap.bounds)
        history.commit(dirtyRect: dirty, actionName: "Text")
        return dirty
    }
}
