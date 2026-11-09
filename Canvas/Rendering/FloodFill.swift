import CoreGraphics
import Foundation

/// Scanline flood fill with per-channel color tolerance.
///
/// Colors are compared **un-premultiplied**, so a semi-transparent area of one color is
/// one region even though its stored (premultiplied) bytes are darker. The fill is
/// applied through Core Graphics with a mask (not by writing raw memory), which keeps
/// the bitmap's copy-on-write image snapshots valid.
enum FloodFill {
    struct Region {
        /// One byte per canvas pixel, row-major: 255 = in the region.
        var mask: [UInt8]
        /// Bounding box of the region in canvas pixels.
        var bounds: CGRect
    }

    /// Fills the region connected to `point` with `color`. Returns the dirty rect.
    @discardableResult
    static func fill(_ bitmap: Bitmap, at point: CGPoint, color: CGColor, tolerance: Int,
                     within selection: Selection? = nil) -> CGRect {
        guard var region = region(in: bitmap,
                                  seedX: Int(point.x.rounded(.down)),
                                  seedY: Int(point.y.rounded(.down)),
                                  tolerance: tolerance) else { return .null }
        if let selection {
            // Only the part of the region that is selected (soft edges included).
            var i = 0
            let count = region.mask.count
            region.mask.withUnsafeMutableBufferPointer { m in
                while i < count {
                    m[i] = UInt8(Int(m[i]) * Int(selection.mask[i]) / 255)
                    i += 1
                }
            }
        }
        paint(region, color: color, into: bitmap)
        return region.bounds
    }

    /// The 4-connected region around the seed whose colors are within `tolerance` (0–255
    /// per channel, alpha included) of the seed pixel's color.
    ///
    /// Two passes keep it fast even in Debug builds: first one tight loop marks every
    /// pixel whose color matches (1), then a scanline fill walks only that byte mask,
    /// marking the connected region (255).
    static func region(in bitmap: Bitmap, seedX: Int, seedY: Int, tolerance: Int) -> Region? {
        let w = bitmap.width, h = bitmap.height
        guard seedX >= 0, seedY >= 0, seedX < w, seedY < h, let raw = bitmap.context.data else { return nil }
        // RGBA bytes read as one little-endian UInt32: r | g << 8 | b << 16 | a << 24.
        let pixels = raw.assumingMemoryBound(to: UInt32.self)
        let rowStride = bitmap.context.bytesPerRow / 4
        let tol = max(0, min(255, tolerance))

        let seed = pixels[seedY * rowStride + seedX]
        let target = unpremultiplied(seed)

        var mask = [UInt8](repeating: 0, count: w * h)
        var minX = seedX, maxX = seedX, minY = seedY, maxY = seedY

        // Hot loops use `while` rather than `for … in` ranges: in Debug builds range
        // iteration isn't optimized and is ~50× slower over millions of pixels.
        mask.withUnsafeMutableBufferPointer { buffer in
            let m = buffer.baseAddress!

            // Pass 1: which pixels have a matching color (ignoring connectivity).
            var y = 0
            while y < h {
                let row = pixels + y * rowStride
                let maskRow = m + y * w
                var x = 0
                while x < w {
                    let v = row[x]
                    if v == seed {
                        maskRow[x] = 1
                    } else if tol > 0 {
                        let c = unpremultiplied(v)
                        if abs(c.r - target.r) <= tol, abs(c.g - target.g) <= tol,
                           abs(c.b - target.b) <= tol, abs(c.a - target.a) <= tol {
                            maskRow[x] = 1
                        }
                    }
                    x += 1
                }
                y += 1
            }

            // Pass 2: scanline fill over the mask; 1 = matching, 255 = in the region.
            var stack = [seedY * w + seedX]
            while let index = stack.popLast() {
                guard m[index] == 1 else { continue }
                let y = index / w
                let rowStart = y * w
                var left = index - rowStart, right = left
                while left > 0, m[rowStart + left - 1] == 1 { left -= 1 }
                while right < w - 1, m[rowStart + right + 1] == 1 { right += 1 }
                var i = left
                while i <= right { m[rowStart + i] = 255; i += 1 }
                if left < minX { minX = left }
                if right > maxX { maxX = right }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                // Queue one seed per run of matching pixels in the rows above and below.
                var neighbourY = y - 1
                while neighbourY <= y + 1 {
                    if neighbourY >= 0 && neighbourY < h {
                        let neighbourStart = neighbourY * w
                        var inRun = false
                        var i = left
                        while i <= right {
                            if m[neighbourStart + i] == 1 {
                                if !inRun { stack.append(neighbourStart + i); inRun = true }
                            } else {
                                inRun = false
                            }
                            i += 1
                        }
                    }
                    neighbourY += 2
                }
            }

            // Matching-but-unconnected pixels are not part of the region.
            var i = 0
            let count = w * h
            while i < count {
                if m[i] == 1 { m[i] = 0 }
                i += 1
            }
        }

        let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Region(mask: mask, bounds: bounds)
    }

    /// Un-premultiplied channels of a packed pixel, as Ints for easy differencing.
    @inline(__always)
    private static func unpremultiplied(_ v: UInt32) -> (r: Int, g: Int, b: Int, a: Int) {
        let a = Int(v >> 24)
        guard a > 0 else { return (0, 0, 0, 0) }
        func un(_ c: Int) -> Int { min(255, (c * 255 + a / 2) / a) }
        return (un(Int(v & 0xFF)), un(Int((v >> 8) & 0xFF)), un(Int((v >> 16) & 0xFF)), a)
    }

    /// Replaces the region's pixels with `color`, using the mask as a clip.
    static func paint(_ region: Region, color: CGColor, into bitmap: Bitmap) {
        let w = bitmap.width
        let x0 = Int(region.bounds.minX), y0 = Int(region.bounds.minY)
        let bw = Int(region.bounds.width), bh = Int(region.bounds.height)

        var cropped = Data(count: bw * bh)
        cropped.withUnsafeMutableBytes { dst in
            region.mask.withUnsafeBufferPointer { src in
                for row in 0..<bh {
                    memcpy(dst.baseAddress! + row * bw, src.baseAddress! + (y0 + row) * w + x0, bw)
                }
            }
        }
        guard let provider = CGDataProvider(data: cropped as CFData),
              let maskImage = CGImage(width: bw, height: bh,
                                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bw,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent) else { return }

        let ctx = bitmap.context
        ctx.saveGState()
        // Same local flip as drawUpright, so mask row 0 lands on the region's top row.
        ctx.translateBy(x: 0, y: region.bounds.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(x: region.bounds.minX, y: 0, width: region.bounds.width, height: region.bounds.height)
        ctx.interpolationQuality = .none
        ctx.clip(to: local, mask: maskImage)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(color)
        ctx.fill(local)
        ctx.restoreGState()
    }
}
