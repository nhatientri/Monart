import CoreGraphics

/// Draws the canvas: background (solid or checkerboard) followed by visible layers.
/// Keeps all compositing in one place so it can move to Metal later if needed.
enum Compositor {
    /// - Parameters:
    ///   - ctx: A context whose user space is canvas pixel coordinates, y pointing down.
    ///   - region: Canvas-space, pixel-aligned rect to redraw.
    ///   - checkerSize: Checkerboard square size in canvas pixels.
    ///   - drawsCheckerboard: When the background is transparent, show a checkerboard
    ///     (on screen) or leave pixels clear (export).
    static func draw(_ model: CanvasModel, in ctx: CGContext, region: CGRect,
                     checkerSize: CGFloat = 8, drawsCheckerboard: Bool = true) {
        let region = region.pixelAligned(clampedTo: model.bounds)
        guard !region.isNull else { return }

        if let background = model.background {
            ctx.setFillColor(background)
            ctx.fill(region)
        } else if drawsCheckerboard {
            drawCheckerboard(in: ctx, region: region, squareSize: checkerSize)
        }

        for layer in model.layers where layer.isVisible && layer.opacity > 0 {
            guard let image = layer.bitmap.makeImage()?.cropping(to: region) else { continue }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(layer.opacity))
            ctx.setBlendMode(layer.blendMode.cgBlendMode)
            ctx.drawUpright(image, in: region)
            ctx.restoreGState()
        }
    }

    /// The composited color of one canvas pixel (background included, checkerboard not).
    static func sampleColor(_ model: CanvasModel, x: Int, y: Int) -> RGBA8 {
        guard x >= 0, y >= 0, x < model.width, y < model.height else { return .clear }
        let probe = Bitmap(width: 1, height: 1)
        probe.context.interpolationQuality = .none
        probe.context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
        draw(model, in: probe.context, region: CGRect(x: x, y: y, width: 1, height: 1), drawsCheckerboard: false)
        return probe.pixel(x: 0, y: 0)
    }

    /// The whole canvas as one image at canvas size, for export.
    /// - Parameter matte: Painted under everything (e.g. white for JPEG, which has no alpha).
    static func flatten(_ model: CanvasModel, matte: CGColor? = nil) -> CGImage? {
        let output = Bitmap(width: model.width, height: model.height)
        output.context.interpolationQuality = .none
        if let matte { output.fill(matte) }
        draw(model, in: output.context, region: model.bounds, drawsCheckerboard: false)
        return output.makeImage()
    }

    private static let checkerLight = CGColor(gray: 1, alpha: 1)
    private static let checkerDark = CGColor(gray: 0.85, alpha: 1)

    static func drawCheckerboard(in ctx: CGContext, region: CGRect, squareSize: CGFloat) {
        let s = max(1, squareSize)
        ctx.saveGState()
        ctx.clip(to: region)
        ctx.setFillColor(checkerLight)
        ctx.fill(region)
        ctx.setFillColor(checkerDark)
        let x0 = Int((region.minX / s).rounded(.down)), x1 = Int((region.maxX / s).rounded(.up))
        let y0 = Int((region.minY / s).rounded(.down)), y1 = Int((region.maxY / s).rounded(.up))
        for j in y0..<y1 {
            for i in x0..<x1 where (i + j) & 1 == 1 {
                ctx.addRect(CGRect(x: CGFloat(i) * s, y: CGFloat(j) * s, width: s, height: s))
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }
}
