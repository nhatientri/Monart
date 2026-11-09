import CoreGraphics

/// Snapping for moving and resizing (Move tool, Free Transform): edges and centers line up
/// with the canvas's edges and center lines when they come within a few screen points.
/// Hold ⌃ while dragging to place freely. View ▸ Snap turns it off altogether.
struct Snapper {
    /// Lines that can be snapped to, in canvas pixels.
    let xs: [CGFloat]
    let ys: [CGFloat]
    /// Snap distance in canvas pixels (a constant on screen, whatever the zoom).
    let threshold: CGFloat

    static let screenThreshold: CGFloat = 8

    init(canvas: CGRect, zoom: CGFloat) {
        xs = [canvas.minX, canvas.midX, canvas.maxX]
        ys = [canvas.minY, canvas.midY, canvas.maxY]
        threshold = Self.screenThreshold / max(zoom, 0.0001)
    }

    /// The snapping to use for this drag, or nil when it's off (setting, or ⌃ held).
    static func forDrag(_ event: ToolEvent, context: ToolContext) -> Snapper? {
        guard context.editor.snapping, !event.modifiers.contains(.control) else { return nil }
        return Snapper(canvas: context.model.bounds, zoom: context.zoom)
    }

    /// The guide lines a snap lined something up with (drawn while dragging).
    struct Guides: Equatable {
        var x: CGFloat?
        var y: CGFloat?
        static let none = Guides()
    }

    /// How far to shift a box so the closest of its left/center/right (top/middle/bottom)
    /// lands on a snap line, if any is close enough.
    func offset(for box: CGRect) -> (delta: CGPoint, guides: Guides) {
        let x = closest([box.minX, box.midX, box.maxX], to: xs)
        let y = closest([box.minY, box.midY, box.maxY], to: ys)
        return (CGPoint(x: x?.delta ?? 0, y: y?.delta ?? 0), Guides(x: x?.line, y: y?.line))
    }

    /// A single point (a dragged corner or edge) snapped to the nearest lines.
    func snap(_ p: CGPoint) -> (point: CGPoint, guides: Guides) {
        let x = closest([p.x], to: xs)
        let y = closest([p.y], to: ys)
        return (CGPoint(x: p.x + (x?.delta ?? 0), y: p.y + (y?.delta ?? 0)), Guides(x: x?.line, y: y?.line))
    }

    private func closest(_ values: [CGFloat], to lines: [CGFloat]) -> (delta: CGFloat, line: CGFloat)? {
        var best: (delta: CGFloat, line: CGFloat)?
        for v in values {
            for line in lines {
                let d = line - v
                if abs(d) <= threshold, abs(d) < abs(best?.delta ?? .infinity) { best = (d, line) }
            }
        }
        return best
    }

    /// Draws the active guides across the canvas (`ctx` in canvas coordinates).
    static func draw(_ guides: Guides, in ctx: CGContext, canvas: CGRect) {
        guard guides != .none else { return }
        let pixel = 1 / max(abs(ctx.ctm.a), 0.0001)
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1))
        ctx.setLineWidth(pixel * 1.5)
        // Lines on the canvas border are pulled just inside it, or the clip would hide half.
        let inset = pixel
        let guides = Guides(x: guides.x.map { min(max($0, canvas.minX + inset), canvas.maxX - inset) },
                            y: guides.y.map { min(max($0, canvas.minY + inset), canvas.maxY - inset) })
        if let x = guides.x {
            ctx.move(to: CGPoint(x: x, y: canvas.minY))
            ctx.addLine(to: CGPoint(x: x, y: canvas.maxY))
        }
        if let y = guides.y {
            ctx.move(to: CGPoint(x: canvas.minX, y: y))
            ctx.addLine(to: CGPoint(x: canvas.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
