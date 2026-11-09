import CoreGraphics
import Foundation

/// Turns a sequence of input points into one brush (or eraser) stroke on a bitmap.
///
/// **Path.** Input points are smoothed with quadratic Béziers through segment midpoints
/// (each input point acts as a control point). Dabs are placed every `spacing × dab size`
/// pixels along the curve, carrying leftover distance between events, so fast strokes
/// have no gaps and slow ones don't clump. Pen pressure is interpolated along the path.
///
/// **Stroke mask.** Dabs don't paint the layer directly. Each one writes its coverage
/// (soft or hard edge, scaled by pressure) into a per-stroke mask, keeping the *maximum*
/// where dabs overlap. The touched area of the layer is then rebuilt as
/// `layer before the stroke + color through the mask at the stroke opacity`.
/// That's why a 50% stroke stays 50% where it crosses itself, and why opacity, softness
/// and pressure all combine predictably.
///
/// **Tips & dynamics.** Each dab is a round, square or image tip (squashed by `roundness`,
/// turned by `angle` and optionally the stroke direction), or a spray of small dots, with
/// optional scatter and size/angle jitter from a fixed-seed generator.
final class StrokeRenderer {
    struct Sample {
        var point: CGPoint
        var pressure: CGFloat
    }

    private let bitmap: Bitmap
    private let baseline: CGImage
    private let color: CGColor
    private let blendMode: CGBlendMode
    private let settings: BrushSettings
    private let clip: Selection?
    private let tipImage: BrushTipImage?
    private var random = SplitMix64(seed: 0xC0FFEE)
    private var lastDabPoint: CGPoint?
    private var direction: CGFloat = 0
    private let width: Int
    private let height: Int
    /// Coverage 0–255 per canvas pixel for this stroke.
    private var mask: [UInt8]

    private var lastInput = Sample(point: .zero, pressure: 1)
    private var lastMid = Sample(point: .zero, pressure: 1)
    private var lastSample = Sample(point: .zero, pressure: 1)
    private var distanceToNextDab: CGFloat = 0

    init(bitmap: Bitmap, color: CGColor, settings: BrushSettings, blendMode: CGBlendMode = .normal,
         clip: Selection? = nil, tipImage: BrushTipImage? = nil) {
        guard let baseline = bitmap.makeImage() else { fatalError("Could not snapshot the layer") }
        self.bitmap = bitmap
        self.baseline = baseline // copy-on-write: costs nothing until the layer changes
        self.color = color
        self.blendMode = blendMode
        self.settings = settings
        self.clip = clip
        // Image-based tips need a picture; without one fall back to round.
        self.tipImage = settings.tip == .chalk ? .chalk : (settings.tip == .image ? tipImage : nil)
        self.width = bitmap.width
        self.height = bitmap.height
        self.mask = [UInt8](repeating: 0, count: bitmap.width * bitmap.height)
    }

    /// Starts the stroke with a single dab. Returns the dirty rect.
    func begin(at point: CGPoint, pressure: CGFloat = 1) -> CGRect {
        let sample = Sample(point: point, pressure: clampPressure(pressure))
        lastInput = sample
        lastMid = sample
        lastSample = sample
        distanceToNextDab = spacing(at: sample.pressure)
        return render([sample])
    }

    /// Extends the stroke toward `point`. `pressure` nil keeps the previous pressure
    /// (e.g. mouse-up, which reports zero). Returns the dirty rect.
    func add(_ point: CGPoint, pressure: CGFloat? = nil) -> CGRect {
        guard point.distance(to: lastInput.point) >= 0.25 else { return .null }
        let sample = Sample(point: point, pressure: pressure.map(clampPressure) ?? lastInput.pressure)
        let mid = Sample(point: lastInput.point.midpoint(point),
                         pressure: (lastInput.pressure + sample.pressure) / 2)
        let curve = Self.quadraticSamples(from: lastMid, control: lastInput, to: mid)
        lastMid = mid
        lastInput = sample
        return render(dabs(along: curve))
    }

    /// Finishes the trailing half-segment up to the last input point.
    func end() -> CGRect {
        render(dabs(along: [lastInput]))
    }

    // MARK: - Dab placement

    private func clampPressure(_ p: CGFloat) -> CGFloat { min(max(p, 0), 1) }

    private func diameter(at pressure: CGFloat) -> CGFloat {
        let scale = settings.pressureControlsSize ? max(BrushSettings.minimumPressureScale, pressure) : 1
        return max(1, settings.size * scale)
    }

    private func spacing(at pressure: CGFloat) -> CGFloat {
        max(0.5, diameter(at: pressure) * settings.spacing)
    }

    /// Walks the polyline from `lastSample` through `samples`, placing dabs at the spacing
    /// for the pressure at each point.
    private func dabs(along samples: [Sample]) -> [Sample] {
        var dabs: [Sample] = []
        for target in samples {
            var from = lastSample
            var remaining = from.point.distance(to: target.point)
            while remaining >= distanceToNextDab {
                let t = distanceToNextDab / remaining
                from = Sample(point: .lerp(from.point, target.point, t),
                              pressure: from.pressure + (target.pressure - from.pressure) * t)
                dabs.append(from)
                remaining -= distanceToNextDab
                distanceToNextDab = spacing(at: from.pressure)
            }
            distanceToNextDab -= remaining
            lastSample = target
        }
        return dabs
    }

    /// Points along a quadratic Bézier (excluding the start), roughly 2 px apart, with
    /// pressure interpolated from start to end.
    static func quadraticSamples(from p0: Sample, control c: Sample, to p2: Sample) -> [Sample] {
        let approxLength = p0.point.distance(to: c.point) + c.point.distance(to: p2.point)
        let steps = max(1, Int((approxLength / 2).rounded(.up)))
        return (1...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let point = p0.point * (u * u) + c.point * (2 * u * t) + p2.point * (t * t)
            return Sample(point: point, pressure: p0.pressure + (p2.pressure - p0.pressure) * t)
        }
    }

    // MARK: - Rendering

    private func render(_ dabs: [Sample]) -> CGRect {
        guard !dabs.isEmpty else { return .null }
        var dirty = CGRect.null
        for dab in dabs {
            if let last = lastDabPoint, last.distance(to: dab.point) > 0.01 {
                direction = atan2(dab.point.y - last.y, dab.point.x - last.x)
            }
            lastDabPoint = dab.point
            dirty = dirty.union(stamp(dab))
        }
        let region = dirty.pixelAligned(clampedTo: bitmap.bounds)
        guard !region.isNull else { return .null }
        composite(region)
        return region
    }

    private enum Shape {
        case round, square, image(BrushTipImage)
    }

    /// One dab: applies the dynamics, then stamps the tip (or a spray of dots).
    private func stamp(_ dab: Sample) -> CGRect {
        var radius = diameter(at: dab.pressure) / 2
        if settings.sizeJitter > 0 { radius *= 1 - min(settings.sizeJitter, 1) * random.unit() }
        radius = max(0.5, radius)
        var center = dab.point
        if settings.scatter > 0 {
            let offset = random.inDisc()
            center = center + offset * (settings.scatter * settings.size)
        }
        var angle = settings.angle * .pi / 180 + (settings.followsStroke ? direction : 0)
        if settings.angleJitter > 0 { angle += (random.unit() * 2 - 1) * min(settings.angleJitter, 1) * .pi }
        let strength = settings.pressureControlsOpacity ? dab.pressure : 1
        let roundness = min(max(settings.roundness, 0.05), 1)

        switch settings.tip {
        case .spray:
            // A handful of small hard dots spread over the dab's area.
            let count = 3 + Int(radius * 0.3)
            let dotRadius = max(0.6, settings.size * 0.035)
            var dirty = CGRect.null
            for _ in 0..<count {
                let at = center + random.inDisc() * radius
                dirty = dirty.union(stampShape(.round, at: at, radius: dotRadius, angle: 0, roundness: 1,
                                               hardness: 1, strength: strength))
            }
            return dirty
        case .square:
            return stampShape(.square, at: center, radius: radius, angle: angle, roundness: roundness,
                              hardness: settings.hardness, strength: strength)
        case .chalk, .image:
            if let tipImage {
                return stampShape(.image(tipImage), at: center, radius: radius, angle: angle, roundness: roundness,
                                  hardness: 1, strength: strength)
            }
            fallthrough
        case .round:
            return stampShape(.round, at: center, radius: radius, angle: angle, roundness: roundness,
                              hardness: settings.hardness, strength: strength)
        }
    }

    /// Writes one tip's coverage into the mask (max with what's there). Returns its bounds.
    ///
    /// Each pixel is mapped into the tip's own unit square (u along the tip's long axis,
    /// v across, both −1…1). Hot loops use `while`: `for … in` ranges are very slow in Debug.
    private func stampShape(_ shape: Shape, at c: CGPoint, radius: CGFloat, angle: CGFloat, roundness: CGFloat,
                            hardness: CGFloat, strength: CGFloat) -> CGRect {
        guard strength > 0 else { return .null }
        var extent = radius
        if case .square = shape { extent = radius * 1.4143 }
        if case .image = shape { extent = radius * 1.4143 }
        let x0 = max(0, Int((c.x - extent - 1).rounded(.down)))
        let x1 = min(width - 1, Int((c.x + extent + 1).rounded(.up)))
        let y0 = max(0, Int((c.y - extent - 1).rounded(.down)))
        let y1 = min(height - 1, Int((c.y + extent + 1).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return .null }

        let cosA = cos(angle), sinA = sin(angle)
        let minorRadius = radius * roundness       // the tip's thin direction, for the 1 px rim
        let core = min(max(hardness, 0), 1)       // solid fraction before the soft falloff
        let w = width
        mask.withUnsafeMutableBufferPointer { buffer in
            let m = buffer.baseAddress!
            var y = y0
            while y <= y1 {
                let dy = CGFloat(y) + 0.5 - c.y
                var x = x0
                while x <= x1 {
                    let dx = CGFloat(x) + 0.5 - c.x
                    let u = (dx * cosA + dy * sinA) / radius
                    let v = (-dx * sinA + dy * cosA) / minorRadius
                    var coverage: CGFloat
                    switch shape {
                    case let .image(tip):
                        coverage = tip.sample(u: u, v: v)
                    case .round, .square:
                        let d: CGFloat
                        if case .square = shape { d = max(abs(u), abs(v)) } else { d = (u * u + v * v).squareRoot() }
                        // 1 px antialiased rim at the outer edge.
                        coverage = min(1, max(0, (1 - d) * minorRadius + 0.5))
                        if coverage > 0 && d > core && core < 1 {
                            let t = min(1, (d - core) / (1 - core))
                            coverage *= 1 - t * t * (3 - 2 * t) // smoothstep falloff
                        }
                    }
                    if coverage > 0 {
                        let value = UInt8(min(255, coverage * strength * 255 + 0.5))
                        let index = y * w + x
                        if value > m[index] { m[index] = value }
                    }
                    x += 1
                }
                y += 1
            }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Rebuilds `region` of the layer as baseline + color through the stroke mask.
    private func composite(_ region: CGRect) {
        let x0 = Int(region.minX), y0 = Int(region.minY)
        let rw = Int(region.width), rh = Int(region.height)

        var bytes = Data(count: rw * rh)
        bytes.withUnsafeMutableBytes { dst in
            mask.withUnsafeBufferPointer { src in
                var row = 0
                while row < rh {
                    memcpy(dst.baseAddress! + row * rw, src.baseAddress! + (y0 + row) * width + x0, rw)
                    row += 1
                }
            }
        }
        // Outside the selection the stroke has no effect.
        clip?.restrict(&bytes, region: region)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let maskImage = CGImage(width: rw, height: rh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rw,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent),
              let before = baseline.cropping(to: region) else { return }

        bitmap.replace(with: before, in: region)

        let ctx = bitmap.context
        ctx.saveGState()
        // Same local flip as drawUpright, so mask row 0 lands on the region's top row.
        ctx.translateBy(x: 0, y: region.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(x: region.minX, y: 0, width: region.width, height: region.height)
        ctx.interpolationQuality = .none
        ctx.clip(to: local, mask: maskImage)
        ctx.setBlendMode(blendMode)
        ctx.setFillColor(color.copy(alpha: color.alpha * min(max(settings.opacity, 0), 1)) ?? color)
        ctx.fill(local)
        ctx.restoreGState()
    }
}
