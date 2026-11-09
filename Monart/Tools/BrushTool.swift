import AppKit

/// Paints the primary color onto the active layer: dabs along a smoothed path, combined
/// through a per-stroke mask (see `StrokeRenderer`). Each stroke is one undo step.
class BrushTool: Tool {
    private var renderer: StrokeRenderer?
    private var strokeDirty = CGRect.null

    // Overridden by EraserTool.
    var blendMode: CGBlendMode { .normal }
    var actionName: String { "Brush Stroke" }
    func strokeColor(_ editor: EditorState) -> CGColor { editor.primaryColor }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let layer = context.model.activeLayer, layer.isVisible else { return .null }
        context.history.beginEdit(on: layer)
        let renderer = StrokeRenderer(bitmap: layer.bitmap,
                                      color: strokeColor(context.editor),
                                      settings: context.editor.brush,
                                      blendMode: blendMode,
                                      clip: context.model.selection,
                                      tipImage: BrushLibrary.shared.tipImage(for: context.editor.brush))
        self.renderer = renderer
        strokeDirty = renderer.begin(at: event.location, pressure: event.pressure)
        return strokeDirty
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let renderer else { return .null }
        let dirty = renderer.add(event.location, pressure: event.pressure)
        strokeDirty = strokeDirty.union(dirty)
        return dirty
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let renderer else { return .null }
        // Mouse-up reports zero pressure on a tablet; keep the last real pressure.
        let dirty = renderer.add(event.location).union(renderer.end())
        strokeDirty = strokeDirty.union(dirty)
        context.history.commit(dirtyRect: strokeDirty, actionName: actionName)
        self.renderer = nil
        strokeDirty = .null
        return dirty
    }
}

/// Cursor showing the brush's outline at its on-screen size.
enum BrushCursor {
    /// Above this the outline is too big for a cursor image; fall back to a crosshair.
    static let maxDiameter: CGFloat = 400
    private static var cache: [Int: NSCursor] = [:]

    /// - Parameter diameter: Brush size in view points (canvas size × zoom).
    static func cursor(diameter: CGFloat) -> NSCursor {
        guard diameter <= maxDiameter else { return .crosshair }
        let key = Int((diameter * 2).rounded())
        if let cached = cache[key] { return cached }
        let cursor = make(diameter: diameter)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = cursor
        return cursor
    }

    private static func make(diameter: CGFloat) -> NSCursor {
        let circle = max(diameter, 1)
        // Room for the outline strokes and the center mark on small brushes.
        let side = ceil(max(circle + 4, 15))
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: side / 2, y: side / 2)
            let rect = NSRect(x: center.x - circle / 2, y: center.y - circle / 2, width: circle, height: circle)
            // White under black: visible on both light and dark paint.
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -0.75, dy: -0.75))
            halo.lineWidth = 1.5
            halo.stroke()
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1
            ring.stroke()
            if circle < 8 {
                // Tiny brushes: a small crosshair so the hot spot is findable.
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: center.x - 5, y: center.y)); mark.line(to: NSPoint(x: center.x - 2, y: center.y))
                mark.move(to: NSPoint(x: center.x + 2, y: center.y)); mark.line(to: NSPoint(x: center.x + 5, y: center.y))
                mark.move(to: NSPoint(x: center.x, y: center.y - 5)); mark.line(to: NSPoint(x: center.x, y: center.y - 2))
                mark.move(to: NSPoint(x: center.x, y: center.y + 2)); mark.line(to: NSPoint(x: center.x, y: center.y + 5))
                mark.lineWidth = 1
                mark.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
