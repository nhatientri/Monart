import CoreGraphics

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (p: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
    static func / (p: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: p.x / s, y: p.y / s) }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func midpoint(_ other: CGPoint) -> CGPoint {
        CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

extension CGRect {
    init(center: CGPoint, radius: CGFloat) {
        self.init(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Expands to whole pixels and clips to `bounds`. Returns `.null` when nothing is left.
    func pixelAligned(clampedTo bounds: CGRect) -> CGRect {
        guard !isNull else { return .null }
        let r = integral.intersection(bounds)
        return r.isEmpty ? .null : r
    }
}
