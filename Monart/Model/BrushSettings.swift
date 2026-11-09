import CoreGraphics
import Foundation

/// The shape stamped along a stroke.
enum BrushTip: String, Codable, CaseIterable, Identifiable {
    case round, square, chalk, spray, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .round: "Round"
        case .square: "Square"
        case .chalk: "Chalk"
        case .spray: "Spray"
        case .image: "Image"
        }
    }
}

/// Brush and eraser settings (shared by both tools). Codable so presets can be saved.
struct BrushSettings: Equatable, Codable {
    static let sizeRange: ClosedRange<CGFloat> = 1...200

    /// Dab diameter in canvas pixels (at full pressure, when pressure controls size).
    var size: CGFloat = 12

    /// Distance between dabs as a fraction of the current dab size.
    var spacing: CGFloat = 0.1

    /// Strength of the whole stroke, 0–1. Overlaps within one stroke never exceed it.
    var opacity: CGFloat = 1

    /// 1 = crisp edge; 0 = soft edge fading from the center (round and square tips).
    var hardness: CGFloat = 1

    /// Pen pressure scales the dab size (a mouse always reports full pressure).
    var pressureControlsSize = true

    /// Pen pressure scales the dab strength.
    var pressureControlsOpacity = false

    // MARK: Tip & dynamics

    var tip: BrushTip = .round
    /// Image tips: the `BrushLibrary` preset whose picture is the tip.
    var tipImageID: UUID?
    /// 1 = full shape; smaller squashes it into a flat nib (calligraphy).
    var roundness: CGFloat = 1
    /// Tip rotation in degrees.
    var angle: CGFloat = 0
    /// Turn the tip to follow the stroke's direction (added to `angle`).
    var followsStroke = false
    /// Random offset of each dab, as a fraction of the size.
    var scatter: CGFloat = 0
    /// 0–1: how much each dab's size may randomly shrink.
    var sizeJitter: CGFloat = 0
    /// 0–1: random rotation of each dab, up to ±180°.
    var angleJitter: CGFloat = 0

    /// Lightest touch still paints at this fraction of the full size, so strokes don't vanish.
    static let minimumPressureScale: CGFloat = 0.1
}

/// A grayscale picture used as a brush tip: 255 = full paint.
struct BrushTipImage: Equatable {
    let width: Int
    let height: Int
    let coverage: [UInt8]

    init(width: Int, height: Int, coverage: [UInt8]) {
        precondition(coverage.count == width * height)
        self.width = width
        self.height = height
        self.coverage = coverage
    }

    /// From any image: dark, opaque pixels paint; light or transparent ones don't (like
    /// "Define Brush" in other paint apps). Scaled down to fit `maxSize`.
    init?(image: CGImage, maxSize: Int = 256) {
        let scale = min(1, CGFloat(maxSize) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let rgba = Bitmap(width: w, height: h)
        rgba.context.interpolationQuality = .high
        rgba.context.drawUpright(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](repeating: 0, count: w * h)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = rgba.pixel(x: x, y: y)
                let luminance = (0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)) / 255
                out[y * w + x] = UInt8((Double(p.a) * (1 - luminance)).rounded())
                x += 1
            }
            y += 1
        }
        guard out.contains(where: { $0 > 0 }) else { return nil }
        self.init(width: w, height: h, coverage: out)
    }

    /// Bilinear sample at unit coordinates u, v ∈ [-1, 1] (the tip's square). 0–1.
    func sample(u: CGFloat, v: CGFloat) -> CGFloat {
        guard u >= -1, u <= 1, v >= -1, v <= 1 else { return 0 }
        let fx = (u + 1) / 2 * CGFloat(width - 1), fy = (v + 1) / 2 * CGFloat(height - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - CGFloat(x0), ty = fy - CGFloat(y0)
        let a = CGFloat(coverage[y0 * width + x0]), b = CGFloat(coverage[y0 * width + x1])
        let c = CGFloat(coverage[y1 * width + x0]), d = CGFloat(coverage[y1 * width + x1])
        return ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty) / 255
    }

    /// For saving presets and showing previews.
    var cgImage: CGImage { Selection.grayImage(coverage, width: width, height: height) }

    /// Built-in textured tip: a soft disc broken up by grainy noise.
    static let chalk: BrushTipImage = {
        let n = 96
        var out = [UInt8](repeating: 0, count: n * n)
        func hash(_ x: Int, _ y: Int) -> Double {
            var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263))
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Double((h ^ (h >> 16)) & 0xFFFF) / 65_535
        }
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) + 0.5) / Double(n) * 2 - 1, dy = (Double(y) + 0.5) / Double(n) * 2 - 1
                let d = (dx * dx + dy * dy).squareRoot()
                guard d < 1 else { continue }
                let disc = min(1, (1 - d) * 3)
                let grain = 0.6 * hash(x, y) + 0.4 * hash(x / 4, y / 4)
                out[y * n + x] = grain > 0.45 ? UInt8(disc * 255) : UInt8(disc * grain * 120)
            }
        }
        return BrushTipImage(width: n, height: n, coverage: out)
    }()
}

/// Small deterministic random numbers (the same stroke always renders the same way).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }

    /// Uniform inside the unit disc.
    mutating func inDisc() -> CGPoint {
        while true {
            let p = CGPoint(x: unit() * 2 - 1, y: unit() * 2 - 1)
            if p.x * p.x + p.y * p.y <= 1 { return p }
        }
    }
}
