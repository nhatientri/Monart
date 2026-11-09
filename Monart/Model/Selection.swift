import CoreGraphics
import Foundation

/// The selected area of the canvas: one coverage byte per pixel (255 = selected,
/// in-between values = soft, antialiased edges). Immutable: every change makes a new
/// `Selection`, and an empty selection is represented as `nil` ("nothing selected").
final class Selection {
    enum Combine {
        case replace, add, subtract, intersect
    }

    let width: Int
    let height: Int
    let mask: [UInt8]
    /// Tight pixel bounds of everything selected.
    let bounds: CGRect

    /// Returns nil when nothing is selected.
    init?(width: Int, height: Int, mask: [UInt8]) {
        precondition(mask.count == width * height, "Mask size mismatch")
        guard let bounds = Self.bounds(of: mask, width: width, height: height) else { return nil }
        self.width = width
        self.height = height
        self.mask = mask
        self.bounds = bounds
    }

    // MARK: - Making selections

    static func all(width: Int, height: Int) -> Selection {
        Selection(width: width, height: height, mask: [UInt8](repeating: 255, count: width * height))!
    }

    /// The area inside `path` (canvas coordinates), with antialiased edges.
    static func shape(_ path: CGPath, width: Int, height: Int) -> Selection? {
        let mask = render(width: width, height: height) { ctx in
            ctx.addPath(path)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath()
        }
        return Selection(width: width, height: height, mask: mask)
    }

    func combined(with existing: Selection?, mode: Combine) -> Selection? {
        guard let existing, mode != .replace else {
            return mode == .subtract || mode == .intersect ? nil : self
        }
        precondition(existing.width == width && existing.height == height)
        var out = [UInt8](repeating: 0, count: mask.count)
        let count = mask.count
        mask.withUnsafeBufferPointer { new in
            existing.mask.withUnsafeBufferPointer { old in
                out.withUnsafeMutableBufferPointer { dst in
                    var i = 0
                    while i < count {
                        let a = Int(old[i]), b = Int(new[i])
                        switch mode {
                        case .add: dst[i] = UInt8(max(a, b))
                        case .subtract: dst[i] = UInt8(a * (255 - b) / 255)
                        case .intersect: dst[i] = UInt8(min(a, b))
                        case .replace: dst[i] = UInt8(b)
                        }
                        i += 1
                    }
                }
            }
        }
        return Selection(width: width, height: height, mask: out)
    }

    func inverted() -> Selection? {
        Selection(width: width, height: height, mask: mask.map { 255 - $0 })
    }

    /// The selection drawn through `transform` (canvas coordinates), e.g. after moving or
    /// scaling the pixels it selects.
    func transformed(_ transform: CGAffineTransform) -> Selection? {
        let source = maskImage
        let w = width, h = height
        let out = Self.render(width: w, height: h) { ctx in
            ctx.concatenate(transform)
            ctx.interpolationQuality = .high
            ctx.drawUpright(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Selection(width: w, height: h, mask: out)
    }

    /// The selection after the pixels in `rect` were distorted so its corners landed on
    /// `quad` (top-left, top-right, bottom-right, bottom-left).
    func warped(from rect: CGRect, to quad: [CGPoint]) -> Selection? {
        let w = width, h = height
        guard let cropped = maskImage.cropping(to: rect) else { return nil }
        let out = Self.render(width: w, height: h) { ctx in
            TransformSession.drawWarped(cropped, to: quad, in: ctx, canvasSize: CGSize(width: w, height: h))
        }
        return Selection(width: w, height: h, mask: out)
    }

    func coverage(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return mask[y * width + x]
    }

    // MARK: - Using selections

    /// Full-canvas grayscale image of the mask (white = selected).
    lazy var maskImage: CGImage = Self.grayImage(mask, width: width, height: height)

    /// Clips `ctx` (a canvas-sized, y-down context) to the selection.
    /// Call between `saveGState()` / `restoreGState()`.
    func clip(_ ctx: CGContext) {
        let h = CGFloat(height)
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: h), mask: maskImage)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -h)
    }

    /// Multiplies `bytes` (a tightly packed mask for `region`) by the selection, in place.
    func restrict(_ bytes: inout Data, region: CGRect) {
        let x0 = Int(region.minX), y0 = Int(region.minY)
        let rw = Int(region.width), rh = Int(region.height)
        bytes.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self).baseAddress!
            mask.withUnsafeBufferPointer { src in
                var row = 0
                while row < rh {
                    let y = y0 + row
                    var col = 0
                    while col < rw {
                        let x = x0 + col
                        let s = (x >= 0 && y >= 0 && x < width && y < height) ? Int(src[y * width + x]) : 0
                        let i = row * rw + col
                        dst[i] = UInt8(Int(dst[i]) * s / 255)
                        col += 1
                    }
                    row += 1
                }
            }
        }
    }

    /// The boundary between selected (≥ 50%) and unselected pixels, along pixel edges,
    /// for drawing marching ants.
    lazy var outline: CGPath = makeOutline()

    // MARK: - Helpers

    /// Renders into a fresh canvas-sized grayscale mask with y-down canvas coordinates.
    static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
        return bytes
    }

    static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Hot loops use `while`: `for … in` ranges are very slow in Debug builds.
    private static func bounds(of mask: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        mask.withUnsafeBufferPointer { m in
            var y = 0
            while y < height {
                let row = y * width
                var x = 0
                while x < width {
                    if m[row + x] != 0 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                    x += 1
                }
                y += 1
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func makeOutline() -> CGPath {
        let path = CGMutablePath()
        let w = width, h = height
        let x0 = Int(bounds.minX), x1 = Int(bounds.maxX), y0 = Int(bounds.minY), y1 = Int(bounds.maxY)
        mask.withUnsafeBufferPointer { m in
            func on(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] >= 128
            }
            // Horizontal edges between rows y-1 and y, merged into runs.
            var y = y0
            while y <= y1 {
                var x = x0, runStart = -1
                while x <= x1 {
                    let edge = on(x, y - 1) != on(x, y)
                    if edge && runStart < 0 { runStart = x }
                    if !edge && runStart >= 0 {
                        path.move(to: CGPoint(x: runStart, y: y)); path.addLine(to: CGPoint(x: x, y: y))
                        runStart = -1
                    }
                    x += 1
                }
                if runStart >= 0 { path.move(to: CGPoint(x: runStart, y: y)); path.addLine(to: CGPoint(x: x, y: y)) }
                y += 1
            }
            // Vertical edges between columns x-1 and x.
            var x = x0
            while x <= x1 {
                var y = y0, runStart = -1
                while y <= y1 {
                    let edge = on(x - 1, y) != on(x, y)
                    if edge && runStart < 0 { runStart = y }
                    if !edge && runStart >= 0 {
                        path.move(to: CGPoint(x: x, y: runStart)); path.addLine(to: CGPoint(x: x, y: y))
                        runStart = -1
                    }
                    y += 1
                }
                if runStart >= 0 { path.move(to: CGPoint(x: x, y: runStart)); path.addLine(to: CGPoint(x: x, y: y)) }
                x += 1
            }
        }
        return path
    }
}
