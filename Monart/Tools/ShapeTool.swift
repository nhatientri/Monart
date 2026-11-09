import AppKit

/// Line, rectangle and ellipse. Shows a live preview while dragging and commits to the
/// active layer on mouse-up. Shift constrains lines to 45° steps and boxes to squares/circles.
final class ShapeTool: Tool {
    enum Shape {
        case line, rectangle, ellipse

        var actionName: String {
            switch self {
            case .line: "Line"
            case .rectangle: "Rectangle"
            case .ellipse: "Ellipse"
            }
        }
    }

    struct Style {
        var color: CGColor
        var lineWidth: CGFloat
        var filled: Bool
    }

    let shape: Shape
    private var start: CGPoint?
    private var current: CGPoint = .zero
    private var style = Style(color: .black, lineWidth: 1, filled: false)
    private var lastPreview = CGRect.null

    init(shape: Shape) {
        self.shape = shape
    }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let layer = context.model.activeLayer, layer.isVisible else { return .null }
        let editor = context.editor
        style = Style(color: editor.primaryColor,
                      lineWidth: editor.shapeLineWidth,
                      filled: editor.shapeFilled && shape != .line)
        start = event.location
        current = event.location
        return updatePreview()
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let start else { return .null }
        current = Self.endPoint(for: shape, from: start, to: event.location,
                                constrained: event.modifiers.contains(.shift))
        return updatePreview()
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let start else { return .null }
        let end = Self.endPoint(for: shape, from: start, to: event.location,
                                constrained: event.modifiers.contains(.shift))
        let preview = lastPreview
        self.start = nil
        lastPreview = .null

        guard start.distance(to: end) >= 1, let layer = context.model.activeLayer else { return preview }
        context.history.beginEdit(on: layer)
        let ctx = layer.bitmap.context
        ctx.saveGState()
        context.model.selection?.clip(ctx)
        Self.render(shape, from: start, to: end, style: style, in: ctx)
        ctx.restoreGState()
        let dirty = Self.bounds(of: shape, from: start, to: end, style: style)
            .pixelAligned(clampedTo: layer.bitmap.bounds)
        context.history.commit(dirtyRect: dirty, actionName: shape.actionName)
        return preview.union(dirty)
    }

    func drawPreview(in ctx: CGContext, context: ToolContext) {
        guard let start else { return }
        Self.render(shape, from: start, to: current, style: style, in: ctx)
    }

    private func updatePreview() -> CGRect {
        guard let start else { return .null }
        let rect = Self.bounds(of: shape, from: start, to: current, style: style)
        defer { lastPreview = rect }
        return lastPreview.union(rect)
    }

    // MARK: - Geometry (static so it can be tested without a view)

    /// The drag end point, optionally constrained (45° lines, squares, circles).
    static func endPoint(for shape: Shape, from start: CGPoint, to point: CGPoint, constrained: Bool) -> CGPoint {
        guard constrained else { return point }
        let d = point - start
        switch shape {
        case .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(d.y, d.x) / step).rounded() * step
            let length = hypot(d.x, d.y)
            return start + CGPoint(x: cos(angle) * length, y: sin(angle) * length)
        case .rectangle, .ellipse:
            let side = max(abs(d.x), abs(d.y))
            return start + CGPoint(x: d.x < 0 ? -side : side, y: d.y < 0 ? -side : side)
        }
    }

    static func path(of shape: Shape, from a: CGPoint, to b: CGPoint, style: Style) -> CGPath {
        let a = snap(a, style), b = snap(b, style)
        let path = CGMutablePath()
        switch shape {
        case .line:
            path.move(to: a)
            path.addLine(to: b)
        case .rectangle:
            path.addRect(CGRect(origin: a, size: CGSize(width: b.x - a.x, height: b.y - a.y)).standardized)
        case .ellipse:
            path.addEllipse(in: CGRect(origin: a, size: CGSize(width: b.x - a.x, height: b.y - a.y)).standardized)
        }
        return path
    }

    static func bounds(of shape: Shape, from a: CGPoint, to b: CGPoint, style: Style) -> CGRect {
        let box = path(of: shape, from: a, to: b, style: style).boundingBoxOfPath
        let outset = (style.filled ? 0 : style.lineWidth / 2) + 2
        return box.insetBy(dx: -outset, dy: -outset)
    }

    static func render(_ shape: Shape, from a: CGPoint, to b: CGPoint, style: Style, in ctx: CGContext) {
        let path = path(of: shape, from: a, to: b, style: style)
        ctx.saveGState()
        ctx.addPath(path)
        if style.filled {
            ctx.setFillColor(style.color)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(style.color)
            ctx.setLineWidth(style.lineWidth)
            ctx.setLineCap(shape == .line ? .round : .butt)
            ctx.setLineJoin(.miter)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Snaps to the pixel grid so 1 px outlines and fills come out crisp: odd stroke
    /// widths sit on pixel centers, even widths and fills on pixel edges.
    private static func snap(_ p: CGPoint, _ style: Style) -> CGPoint {
        let oddStroke = !style.filled && Int(style.lineWidth.rounded()) % 2 == 1
        return oddStroke
            ? CGPoint(x: p.x.rounded(.down) + 0.5, y: p.y.rounded(.down) + 0.5)
            : CGPoint(x: p.x.rounded(), y: p.y.rounded())
    }
}
