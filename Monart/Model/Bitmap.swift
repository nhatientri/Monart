import CoreGraphics
import Foundation

/// An 8-bit premultiplied RGBA pixel buffer backed by a `CGContext`.
///
/// The context's CTM is flipped once at creation so that drawing uses
/// **canvas pixel coordinates**: origin at the top-left, y pointing down.
/// Memory row 0 is therefore canvas row 0.
final class Bitmap {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    static let maxDimension = 16_384

    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        precondition((1...Self.maxDimension).contains(width) && (1...Self.maxDimension).contains(height),
                     "Bitmap size out of range: \(width)×\(height)")
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: Self.colorSpace,
                                      bitmapInfo: Self.bitmapInfo) else {
            fatalError("Could not allocate a \(width)×\(height) bitmap")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high

        self.width = width
        self.height = height
        self.context = context
        clear()
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    func clear() {
        context.clear(bounds)
    }

    func fill(_ color: CGColor, in rect: CGRect? = nil) {
        context.saveGState()
        context.setFillColor(color)
        context.fill(rect ?? bounds)
        context.restoreGState()
    }

    /// A snapshot image of the current pixels (copy-on-write, cheap until the next draw).
    func makeImage() -> CGImage? {
        context.makeImage()
    }

    /// Replaces every pixel with `other`'s. Both bitmaps must be the same size.
    func copyContents(of other: Bitmap) {
        precondition(other.width == width && other.height == height, "Bitmap size mismatch")
        guard let image = other.makeImage() else { return }
        replace(with: image, in: bounds)
    }

    /// Raw premultiplied RGBA bytes for `rect` (expanded to whole pixels, clipped to bounds),
    /// top row first, tightly packed.
    func pixelData(in rect: CGRect) -> Data {
        let r = rect.pixelAligned(clampedTo: bounds)
        guard !r.isNull, let base = context.data else { return Data() }
        let x = Int(r.minX), y = Int(r.minY), w = Int(r.width), h = Int(r.height)
        let rowBytes = w * 4, bytesPerRow = context.bytesPerRow
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for row in 0..<h {
                memcpy(dstBase + row * rowBytes, base + (y + row) * bytesPerRow + x * 4, rowBytes)
            }
        }
        return data
    }

    /// Writes bytes produced by `pixelData(in:)` back into the same pixel-aligned `rect`.
    ///
    /// This draws through Core Graphics rather than writing raw memory, so images
    /// previously returned by `makeImage()` (which share memory copy-on-write) stay correct.
    func setPixelData(_ data: Data, in rect: CGRect) {
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0, data.count == w * h * 4,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: Self.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return }
        replace(with: image, in: rect)
    }

    /// Copies `image` into `rect` exactly (no blending, no resampling).
    func replace(with image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.drawUpright(image, in: rect)
        context.restoreGState()
    }

    /// A downscaled copy no larger than `maxPixelSize` on its longest side, for thumbnails.
    func makeThumbnail(maxPixelSize: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(width, height)))
        let w = max(1, Int((CGFloat(width) * scale).rounded()))
        let h = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let image = makeImage(),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        // A plain (unflipped) context draws CGImages upright as-is.
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The un-premultiplied color at a canvas pixel, or `.clear` when out of bounds.
    func pixel(x: Int, y: Int) -> RGBA8 {
        guard x >= 0, y >= 0, x < width, y < height, let data = context.data else { return .clear }
        let p = data.advanced(by: y * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return RGBA8(premultipliedR: p[0], g: p[1], b: p[2], a: p[3])
    }
}

extension CGContext {
    /// Draws `image` (top row first) into `rect` of a y-down context without it appearing upside down.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}
