import CoreGraphics

/// An un-premultiplied 8-bit sRGB color.
struct RGBA8: Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    static let clear = RGBA8(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Converts from premultiplied storage.
    init(premultipliedR r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard a > 0 else { self = .clear; return }
        func un(_ c: UInt8) -> UInt8 {
            UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a)))
        }
        self.init(r: un(r), g: un(g), b: un(b), a: a)
    }
}

extension CGColor {
    /// This color converted to sRGB and quantized to 8 bits per channel.
    var rgba8: RGBA8 {
        guard let c = converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 4 else { return .clear }
        func q(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return RGBA8(r: q(comps[0]), g: q(comps[1]), b: q(comps[2]), a: q(comps[3]))
    }
}
