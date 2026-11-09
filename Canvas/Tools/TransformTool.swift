import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Lifts the selected pixels of the active layer (or everything painted on it when nothing
/// is selected) so they can be moved, scaled, rotated or distorted, then applied as one undo step.
///
/// While a session is open the layer shows `hole` (the layer without the lifted pixels) with
/// `source` drawn on top through the current transform.
final class TransformSession {
    let layer: Layer
    let sourceRect: CGRect
    private let model: CanvasModel
    private let history: HistoryManager
    private let original: CGImage
    private let hole: CGImage
    private let source: CGImage
    private let selection: Selection?
    private(set) var transform: CGAffineTransform = .identity
    /// Where the corners of `sourceRect` (top-left, top-right, bottom-right, bottom-left) went
    /// when the pixels were distorted rather than just transformed; nil otherwise.
    private(set) var quad: [CGPoint]?
    /// Where the lifted pixels were last drawn (at first: where they came from), so a step
    /// reports only what it changed.
    private var drawnRect: CGRect

    /// Nil when there's nothing to transform (hidden layer, empty layer or empty selection).
    init?(model: CanvasModel, history: HistoryManager) {
        guard let layer = model.activeLayer, layer.isVisible,
              let original = layer.bitmap.makeImage() else { return nil }
        let selection = model.selection
        guard let rect = selection?.bounds ?? Self.contentBounds(of: layer.bitmap) else { return nil }

        // The pixels that move, cropped to their bounds (soft selection edges included).
        let crop = Bitmap(width: Int(rect.width), height: Int(rect.height))
        crop.context.saveGState()
        crop.context.translateBy(x: -rect.minX, y: -rect.minY)
        selection?.clip(crop.context)
        crop.context.drawUpright(original, in: model.bounds)
        crop.context.restoreGState()

        // What stays behind.
        let rest = Bitmap(width: model.width, height: model.height)
        rest.replace(with: original, in: model.bounds)
        rest.context.saveGState()
        selection?.clip(rest.context)
        rest.context.setBlendMode(.destinationOut)
        rest.context.setFillColor(CGColor(gray: 0, alpha: 1))
        rest.context.fill(rect)
        rest.context.restoreGState()

        guard let source = crop.makeImage(), let hole = rest.makeImage() else { return nil }
        self.layer = layer
        self.model = model
        self.history = history
        self.original = original
        self.hole = hole
        self.source = source
        self.sourceRect = rect
        self.drawnRect = rect
        self.selection = selection
        history.beginEdit(on: layer)
    }

    /// Shows the lifted pixels through `t` (canvas coordinates). Returns the area to redraw.
    @discardableResult
    func apply(_ t: CGAffineTransform) -> CGRect {
        transform = t
        quad = nil
        let bitmap = layer.bitmap
        bitmap.replace(with: hole, in: model.bounds)
        let ctx = bitmap.context
        ctx.saveGState()
        ctx.concatenate(t)
        // Whole-pixel moves stay crisp; anything else is resampled smoothly.
        let isWholePixelMove = t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1
            && t.tx == t.tx.rounded() && t.ty == t.ty.rounded()
        ctx.interpolationQuality = isWholePixelMove ? .none : .high
        ctx.drawUpright(source, in: sourceRect)
        ctx.restoreGState()
        return changed(sourceRect.applying(t))
    }

    /// The old and new placement, padded for resampling, clamped to the canvas.
    private func changed(_ newRect: CGRect) -> CGRect {
        defer { drawnRect = newRect }
        return drawnRect.union(newRect).insetBy(dx: -2, dy: -2).intersection(model.bounds)
    }

    /// Shows the lifted pixels stretched so the corners of `sourceRect` land on `corners`
    /// (top-left, top-right, bottom-right, bottom-left) — skew and perspective.
    @discardableResult
    func apply(quad corners: [CGPoint]) -> CGRect {
        precondition(corners.count == 4)
        transform = .identity
        quad = corners
        let bitmap = layer.bitmap
        bitmap.replace(with: hole, in: model.bounds)
        Self.drawWarped(source, to: corners, in: bitmap.context, canvasSize: model.bounds.size)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return changed(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
    }

    /// Keeps the result as one undo step and moves the selection along with the pixels.
    func commit(actionName: String) {
        if let quad {
            history.commit(dirtyRect: model.bounds, actionName: actionName)
            if let selection { model.selection = selection.warped(from: sourceRect, to: quad) }
            return
        }
        guard !transform.isIdentity else { return cancel() }
        history.commit(dirtyRect: model.bounds, actionName: actionName)
        if let selection { model.selection = selection.transformed(transform) }
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: Bitmap.colorSpace,
                                                       .outputColorSpace: Bitmap.colorSpace])

    /// Draws `image` into a canvas-sized, y-down `ctx`, warped so its corners land on `quad`
    /// (top-left, top-right, bottom-right, bottom-left).
    ///
    /// The image's border pixels are extended outward before warping and the result is cut
    /// to the quad with an anti-aliased clip: warping the plain image would blend its edges
    /// with the transparent space around it, and a small image stretched a lot would get
    /// edges several pixels soft.
    static func drawWarped(_ image: CGImage, to quad: [CGPoint], in ctx: CGContext, canvasSize: CGSize) {
        guard let warped = warp(image, to: quad, canvasSize: canvasSize) else { return }
        ctx.saveGState()
        ctx.addLines(between: quad)
        ctx.closePath()
        ctx.clip()
        ctx.drawUpright(warped.image, in: warped.rect)
        ctx.restoreGState()
    }

    /// The warped pixels covering the quad's bounding box (cropped to the canvas), with the
    /// image's edges extended a little beyond the quad, and where to draw them.
    private static func warp(_ image: CGImage, to quad: [CGPoint], canvasSize: CGSize) -> (image: CGImage, rect: CGRect)? {
        // Pad by repeating the border pixels, and place the padded corners with the same
        // perspective mapping, so the quad itself still gets exactly the original image.
        // (Strong perspective can put the padded corners past the horizon: then try less.)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var input = CIImage(cgImage: image)
        var target = quad
        let mapping = Homography(unitSquareTo: quad)
        for pad: CGFloat in [2, 1] {
            let padded = [CGPoint(x: -pad / w, y: -pad / h), CGPoint(x: 1 + pad / w, y: -pad / h),
                          CGPoint(x: 1 + pad / w, y: 1 + pad / h), CGPoint(x: -pad / w, y: 1 + pad / h)]
                .compactMap(mapping.map)
            if padded.count == 4 {
                input = input.clampedToExtent().cropped(to: input.extent.insetBy(dx: -pad, dy: -pad))
                target = padded
                break
            }
        }
        // Core Image is y-up; the canvas is y-down.
        func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: canvasSize.height - p.y) }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = input
        filter.topLeft = ci(target[0])
        filter.topRight = ci(target[1])
        filter.bottomRight = ci(target[2])
        filter.bottomLeft = ci(target[3])
        guard let output = filter.outputImage else { return nil }
        let xs = quad.map(\.x), ys = quad.map { canvasSize.height - $0.y }
        let quadBox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let extent = quadBox.insetBy(dx: -1, dy: -1).intersection(CGRect(origin: .zero, size: canvasSize)).integral
        guard !extent.isNull, !extent.isEmpty,
              let result = ciContext.createCGImage(output, from: extent, format: .RGBA8,
                                                   colorSpace: Bitmap.colorSpace) else { return nil }
        return (result, CGRect(x: extent.minX, y: canvasSize.height - extent.maxY,
                               width: extent.width, height: extent.height))
    }

    /// Puts the layer back exactly as it was.
    func cancel() {
        layer.bitmap.replace(with: original, in: model.bounds)
        history.cancelEdit()
        layer.noteContentChanged()
    }

    /// Bounds of the non-transparent pixels, or nil for an empty layer.
    static func contentBounds(of bitmap: Bitmap) -> CGRect? {
        guard let data = bitmap.context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = bitmap.context.bytesPerRow
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        var y = 0
        while y < bitmap.height {
            let row = pixels + y * bytesPerRow
            var x = 0
            while x < bitmap.width {
                if row[x * 4 + 3] != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// The perspective mapping that takes the unit square's corners (0,0), (1,0), (1,1), (0,1)
/// to a quad's corners in the same order (Heckbert's square-to-quad).
struct Homography {
    private let a, b, c, d, e, f, g, h: CGFloat

    init(unitSquareTo q: [CGPoint]) {
        let dx1 = q[1].x - q[2].x, dx2 = q[3].x - q[2].x, dx3 = q[0].x - q[1].x + q[2].x - q[3].x
        let dy1 = q[1].y - q[2].y, dy2 = q[3].y - q[2].y, dy3 = q[0].y - q[1].y + q[2].y - q[3].y
        let det = dx1 * dy2 - dx2 * dy1
        if (dx3 == 0 && dy3 == 0) || det == 0 {
            g = 0; h = 0
        } else {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        a = q[1].x - q[0].x + g * q[1].x
        b = q[3].x - q[0].x + h * q[3].x
        c = q[0].x
        d = q[1].y - q[0].y + g * q[1].y
        e = q[3].y - q[0].y + h * q[3].y
        f = q[0].y
    }

    /// Nil past the horizon (the point would land behind the viewer).
    func map(_ p: CGPoint) -> CGPoint? {
        let w = g * p.x + h * p.y + 1
        guard w > 0.0001 else { return nil }
        return CGPoint(x: (a * p.x + b * p.y + c) / w, y: (d * p.x + e * p.y + f) / w)
    }
}

/// Move tool (V): drag the selected pixels, or the whole layer when nothing is selected.
/// Shift keeps the move horizontal or vertical; edges and centers snap to the canvas's.
final class MoveTool: Tool {
    var cursor: NSCursor { .arrow }
    private var session: TransformSession?
    private var grabbed: CGPoint = .zero
    private var guides = Snapper.Guides.none

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        session = TransformSession(model: context.model, history: context.history)
        grabbed = event.location
        return .null
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let session else { return .null }
        var d = event.location - grabbed
        var lockX = false, lockY = false
        if event.modifiers.contains(.shift) {
            if abs(d.x) > abs(d.y) { d.y = 0; lockY = true } else { d.x = 0; lockX = true }
        }
        guides = .none
        if let snapper = Snapper.forDrag(event, context: context) {
            let snap = snapper.offset(for: session.sourceRect.offsetBy(dx: d.x, dy: d.y))
            if !lockX { d.x += snap.delta.x; guides.x = snap.guides.x }
            if !lockY { d.y += snap.delta.y; guides.y = snap.guides.y }
        }
        return session.apply(CGAffineTransform(translationX: d.x.rounded(), y: d.y.rounded()))
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guides = .none
        guard let session else { return .null }
        session.commit(actionName: "Move")
        self.session = nil
        return context.model.bounds
    }

    func drawPreview(in ctx: CGContext, context: ToolContext) {
        Snapper.draw(guides, in: ctx, canvas: context.model.bounds)
    }
}

/// Free Transform (⌘T, and automatically after pasting or dropping an image): a box with
/// handles around the lifted pixels. Corner handles scale (Shift keeps proportions), edge
/// handles stretch, ⌘-dragging a corner moves just that corner (distort / perspective),
/// dragging inside moves, dragging outside rotates (Shift snaps to 15°). Applied or
/// cancelled by the canvas view (Return / Esc, or the options bar).
///
/// The box is an affine transform (center, size, angle) of the source rect, plus an optional
/// per-corner offset in source pixels for distortion, so scaling and rotating keep working
/// on a distorted image.
final class FreeTransformTool: Tool {
    let session: TransformSession
    private let sourceCenter: CGPoint
    private let sourceSize: CGSize

    // Current box: center, size (canvas pixels) and rotation.
    private var center: CGPoint
    private var size: CGSize
    private var angle: CGFloat = 0
    /// Per-corner distortion in source pixels: top-left, top-right, bottom-right, bottom-left.
    private var offsets = [CGPoint](repeating: .zero, count: 4)
    private let sourceCorners: [CGPoint]

    private enum Handle {
        case corner(sx: CGFloat, sy: CGFloat)
        case edgeX(sx: CGFloat)
        case edgeY(sy: CGFloat)
        case distort(Int)
        case move, rotate
    }
    /// Corner signs in `sourceCorners` order.
    private static let cornerSigns: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    private var handle: Handle?
    private var guides = Snapper.Guides.none
    private var start = (center: CGPoint.zero, size: CGSize.zero, angle: CGFloat(0), point: CGPoint.zero)

    init(session: TransformSession) {
        self.session = session
        let rect = session.sourceRect
        sourceCenter = CGPoint(x: rect.midX, y: rect.midY)
        sourceSize = rect.size
        center = sourceCenter
        size = rect.size
        sourceCorners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    var isDistorted: Bool { offsets.contains { $0 != .zero } }

    /// Where the four corners are now, on the canvas.
    var corners: [CGPoint] {
        let t = transform
        return (0..<4).map { (sourceCorners[$0] + offsets[$0]).applying(t) }
    }

    private func applyToSession() -> CGRect {
        isDistorted ? session.apply(quad: corners) : session.apply(transform)
    }

    var cursor: NSCursor { .crosshair }

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .scaledBy(x: size.width / sourceSize.width, y: size.height / sourceSize.height)
            .translatedBy(x: -sourceCenter.x, y: -sourceCenter.y)
    }

    /// Arrow keys while transforming.
    func nudge(by delta: CGPoint) -> CGRect {
        center = center + delta
        return applyToSession()
    }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        handle = hitTest(event.location, zoom: context.zoom, distort: event.modifiers.contains(.command))
        start = (center, size, angle, event.location)
        return .null
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let handle else { return .null }
        var p = event.location
        let shift = event.modifiers.contains(.shift)
        let snapper = Snapper.forDrag(event, context: context)
        guides = .none
        switch handle {
        case .corner, .edgeX, .edgeY, .distort:
            // The dragged corner or edge lands on a canvas edge or center line.
            if let snapper {
                let snap = snapper.snap(p)
                p = snap.point
                guides = snap.guides
                if case .edgeX = handle { p.y = event.location.y; guides.y = nil }
                if case .edgeY = handle { p.x = event.location.x; guides.x = nil }
            }
        case .move, .rotate:
            break
        }
        switch handle {
        case let .distort(i):
            offsets[i] = p.applying(transform.inverted()) - sourceCorners[i]
        case .move:
            var d = p - start.point
            var lockX = false, lockY = false
            if shift { if abs(d.x) > abs(d.y) { d.y = 0; lockY = true } else { d.x = 0; lockX = true } }
            if let snapper {
                // The whole box's edges or center line up with the canvas's.
                let shift = start.center + d - center
                let box = Self.boundingBox(corners).offsetBy(dx: shift.x, dy: shift.y)
                let snap = snapper.offset(for: box)
                if !lockX { d.x += snap.delta.x; guides.x = snap.guides.x }
                if !lockY { d.y += snap.delta.y; guides.y = snap.guides.y }
            }
            center = start.center + d
        case .rotate:
            let a0 = atan2(start.point.y - start.center.y, start.point.x - start.center.x)
            let a1 = atan2(p.y - start.center.y, p.x - start.center.x)
            var a = start.angle + (a1 - a0)
            if shift { a = (a / (.pi / 12)).rounded() * (.pi / 12) }
            angle = a
        case let .corner(sx, sy):
            let anchor = start.center + rotated(CGPoint(x: -sx * start.size.width / 2, y: -sy * start.size.height / 2), by: angle)
            let d = rotated(p - anchor, by: -angle)
            var w = max(1, d.x * sx), h = max(1, d.y * sy)
            if shift {
                let s = max(w / start.size.width, h / start.size.height)
                w = start.size.width * s
                h = start.size.height * s
            }
            size = CGSize(width: w, height: h)
            center = anchor + rotated(CGPoint(x: sx * w / 2, y: sy * h / 2), by: angle)
        case let .edgeX(sx):
            let anchor = start.center + rotated(CGPoint(x: -sx * start.size.width / 2, y: 0), by: angle)
            let w = max(1, rotated(p - anchor, by: -angle).x * sx)
            let h = shift ? start.size.height * w / start.size.width : start.size.height
            size = CGSize(width: w, height: h)
            center = anchor + rotated(CGPoint(x: sx * w / 2, y: 0), by: angle)
        case let .edgeY(sy):
            let anchor = start.center + rotated(CGPoint(x: 0, y: -sy * start.size.height / 2), by: angle)
            let h = max(1, rotated(p - anchor, by: -angle).y * sy)
            let w = shift ? start.size.width * h / start.size.height : start.size.width
            size = CGSize(width: w, height: h)
            center = anchor + rotated(CGPoint(x: 0, y: sy * h / 2), by: angle)
        }
        return applyToSession()
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        handle = nil
        guides = .none
        return context.model.bounds
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func drawPreview(in ctx: CGContext, context: ToolContext) {
        let pixel = 1 / max(abs(ctx.ctm.a), 0.0001)
        let corners = self.corners
        ctx.saveGState()
        ctx.addLines(between: corners + [corners[0]])
        ctx.setLineWidth(pixel * 2)
        ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1))
        ctx.strokePath()
        let half = 4 * pixel * 2
        for point in corners + edgeMidpoints(corners) {
            let r = CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(r)
            ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 1))
            ctx.stroke(r, width: pixel * 2)
        }
        ctx.restoreGState()
        Snapper.draw(guides, in: ctx, canvas: context.model.bounds)
    }

    // MARK: - Geometry

    private func rotated(_ p: CGPoint, by a: CGFloat) -> CGPoint {
        CGPoint(x: p.x * cos(a) - p.y * sin(a), y: p.x * sin(a) + p.y * cos(a))
    }

    /// Top, right, bottom, left.
    private func edgeMidpoints(_ c: [CGPoint]) -> [CGPoint] {
        (0..<4).map { CGPoint(x: (c[$0].x + c[($0 + 1) % 4].x) / 2, y: (c[$0].y + c[($0 + 1) % 4].y) / 2) }
    }

    private func hitTest(_ p: CGPoint, zoom: CGFloat, distort: Bool) -> Handle {
        let tolerance = 8 / max(zoom, 0.0001)
        func near(_ q: CGPoint) -> Bool { abs(p.x - q.x) <= tolerance && abs(p.y - q.y) <= tolerance }
        let corners = self.corners
        if let i = corners.firstIndex(where: near) {
            let (sx, sy) = Self.cornerSigns[i]
            return distort ? .distort(i) : .corner(sx: sx, sy: sy)
        }
        let edges: [Handle] = [.edgeY(sy: -1), .edgeX(sx: 1), .edgeY(sy: 1), .edgeX(sx: -1)]
        if let i = edgeMidpoints(corners).firstIndex(where: near) { return edges[i] }
        return Self.contains(corners, p) ? .move : .rotate
    }

    /// Point in a (possibly non-convex) quadrilateral, even-odd rule.
    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
