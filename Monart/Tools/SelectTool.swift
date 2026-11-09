import AppKit

extension Selection.Combine {
    /// Shift adds, ⌥ subtracts, both intersect (pressed when the drag starts).
    init(modifiers: NSEvent.ModifierFlags) {
        switch (modifiers.contains(.shift), modifiers.contains(.option)) {
        case (true, true): self = .intersect
        case (true, false): self = .add
        case (false, true): self = .subtract
        case (false, false): self = .replace
        }
    }
}

/// Drag out a rectangle, ellipse or freehand (lasso) selection.
final class SelectTool: Tool {
    private var shape: EditorState.SelectShape = .rectangle
    private var points: [CGPoint] = []
    private var mode: Selection.Combine = .replace
    private var lastPreview = CGRect.null

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        shape = context.editor.selectShape
        mode = Selection.Combine(modifiers: event.modifiers)
        points = [event.location]
        return .null
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard !points.isEmpty else { return .null }
        if shape == .lasso {
            points.append(event.location)
        } else {
            points = [points[0], event.location]
        }
        return updatePreview()
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard !points.isEmpty else { return .null }
        let preview = lastPreview
        defer {
            points = []
            lastPreview = .null
        }
        let model = context.model
        let path = makePath()
        let box = path.boundingBoxOfPath
        // A click without a drag deselects (when not adding or subtracting).
        guard box.width >= 1 || box.height >= 1, points.count >= 2 else {
            if mode == .replace { model.selection = nil }
            return preview
        }
        let shapeSelection = Selection.shape(path, width: model.width, height: model.height)
        if let shapeSelection {
            model.selection = shapeSelection.combined(with: model.selection, mode: mode)
        } else if mode == .replace || mode == .intersect {
            model.selection = nil
        }
        return preview
    }

    func drawPreview(in ctx: CGContext, context: ToolContext) {
        guard points.count >= 2 else { return }
        SelectionOutline.stroke(makePath(), in: ctx, phase: 0)
    }

    private func makePath() -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle, .ellipse:
            let a = points[0], b = points.last ?? a
            let rect = CGRect(x: min(a.x, b.x).rounded(), y: min(a.y, b.y).rounded(),
                              width: abs(b.x - a.x).rounded(), height: abs(b.y - a.y).rounded())
            shape == .rectangle ? path.addRect(rect) : path.addEllipse(in: rect)
        case .lasso:
            path.addLines(between: points)
            path.closeSubpath()
        }
        return path
    }

    private func updatePreview() -> CGRect {
        let rect = makePath().boundingBoxOfPath.insetBy(dx: -3, dy: -3)
        defer { lastPreview = rect }
        return lastPreview.union(rect)
    }
}

/// Click to select the connected area of similar color on the active layer.
final class MagicWandTool: Tool {
    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let layer = context.model.activeLayer else { return .null }
        let model = context.model
        let mode = Selection.Combine(modifiers: event.modifiers)
        let tolerance = Int((context.editor.fillTolerance * 255).rounded())
        guard let region = FloodFill.region(in: layer.bitmap,
                                            seedX: Int(event.location.x.rounded(.down)),
                                            seedY: Int(event.location.y.rounded(.down)),
                                            tolerance: tolerance) else { return .null }
        let mask = Self.includingSoftEdge(region.mask, of: layer.bitmap)
        if let picked = Selection(width: model.width, height: model.height, mask: mask) {
            model.selection = picked.combined(with: model.selection, mode: mode)
        }
        return .null
    }

    /// Grows the picked area through every connected (8-way) partly transparent pixel —
    /// the antialiased or soft edge of painted shapes — so moving or cutting them leaves no
    /// faint halo. Fully transparent and fully opaque pixels stop the growth, so another
    /// color on a filled layer is never grabbed.
    static func includingSoftEdge(_ mask: [UInt8], of bitmap: Bitmap) -> [UInt8] {
        guard let data = bitmap.context.data else { return mask }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = bitmap.context.bytesPerRow
        let w = bitmap.width, h = bitmap.height
        var out = mask
        out.withUnsafeMutableBufferPointer { o in
            func isSoft(_ x: Int, _ y: Int) -> Bool {
                let alpha = pixels[y * bytesPerRow + x * 4 + 3]
                return alpha > 0 && alpha < 255
            }
            // Seed with every picked pixel, then flood outward through soft pixels.
            var stack: [Int] = []
            var i = 0
            let count = w * h
            while i < count {
                if o[i] != 0 { stack.append(i) }
                i += 1
            }
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                var dy = -1
                while dy <= 1 {
                    var dx = -1
                    while dx <= 1 {
                        let nx = x + dx, ny = y + dy
                        if (dx != 0 || dy != 0) && nx >= 0 && ny >= 0 && nx < w && ny < h {
                            let n = ny * w + nx
                            if o[n] == 0 && isSoft(nx, ny) {
                                o[n] = 255
                                stack.append(n)
                            }
                        }
                        dx += 1
                    }
                    dy += 1
                }
            }
        }
        return out
    }
}

/// Marching ants: a black-and-white dashed line, one device pixel wide at any zoom.
enum SelectionOutline {
    static func stroke(_ path: CGPath, in ctx: CGContext, phase: CGFloat) {
        // ctx is in canvas coordinates; undo the zoom so the line stays thin and the dashes even.
        let scale = max(abs(ctx.ctm.a), 0.0001)
        let pixel = 1 / scale
        let dash = 4 * pixel * 2
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(pixel * 2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setLineDash(phase: phase * pixel * 2, lengths: [dash, dash])
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
