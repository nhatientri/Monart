import XCTest
@testable import Canvas

final class StrokeRendererTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func makeRenderer(_ bitmap: Bitmap, size: CGFloat = 4) -> StrokeRenderer {
        var settings = BrushSettings()
        settings.size = size
        return StrokeRenderer(bitmap: bitmap, color: red, settings: settings)
    }

    /// A single huge jump between events (a very fast mouse move) must still be continuous.
    func testFastStrokeHasNoGaps() {
        let bitmap = Bitmap(width: 300, height: 100)
        let renderer = makeRenderer(bitmap)
        _ = renderer.begin(at: CGPoint(x: 10, y: 50))
        _ = renderer.add(CGPoint(x: 290, y: 50))
        _ = renderer.end()

        for x in 10...290 {
            XCTAssertGreaterThan(bitmap.pixel(x: x, y: 50).a, 200, "gap at x=\(x)")
        }
        XCTAssertEqual(bitmap.pixel(x: 150, y: 10), .clear)
    }

    /// Everything painted must fall inside the dirty rects reported to the view.
    func testDirtyRectsCoverAllPaintedPixels() {
        let bitmap = Bitmap(width: 200, height: 200)
        let renderer = makeRenderer(bitmap, size: 9)
        var dirty = renderer.begin(at: CGPoint(x: 20, y: 20))
        for p in [CGPoint(x: 80, y: 40), CGPoint(x: 120, y: 150), CGPoint(x: 60, y: 180), CGPoint(x: 30, y: 100)] {
            dirty = dirty.union(renderer.add(p))
        }
        dirty = dirty.union(renderer.end())

        for y in 0..<200 {
            for x in 0..<200 where bitmap.pixel(x: x, y: y).a > 0 {
                XCTAssertTrue(dirty.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)),
                              "painted pixel (\(x), \(y)) outside dirty rect \(dirty)")
            }
        }
    }

    /// The stroke reaches its final point once ended.
    func testStrokeEndsAtLastPoint() {
        let bitmap = Bitmap(width: 100, height: 100)
        let renderer = makeRenderer(bitmap)
        _ = renderer.begin(at: CGPoint(x: 10, y: 10))
        _ = renderer.add(CGPoint(x: 50, y: 10))
        _ = renderer.add(CGPoint(x: 50, y: 80))
        XCTAssertEqual(bitmap.pixel(x: 50, y: 80), .clear, "smoothing lags half a segment before end()")
        _ = renderer.end()
        XCTAssertGreaterThan(bitmap.pixel(x: 50, y: 80).a, 200)
    }

    func testBrushUsesPrimaryColor() {
        let bitmap = Bitmap(width: 50, height: 50)
        let renderer = makeRenderer(bitmap, size: 10)
        _ = renderer.begin(at: CGPoint(x: 25, y: 25))
        XCTAssertEqual(bitmap.pixel(x: 25, y: 25), red.rgba8)
    }

    func testEraserClearsPaint() {
        let bitmap = Bitmap(width: 100, height: 40)
        bitmap.fill(red)
        var settings = BrushSettings()
        settings.size = 10
        let eraser = StrokeRenderer(bitmap: bitmap, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                    settings: settings, blendMode: .destinationOut)
        _ = eraser.begin(at: CGPoint(x: 10, y: 20))
        _ = eraser.add(CGPoint(x: 90, y: 20))
        _ = eraser.end()

        XCTAssertEqual(bitmap.pixel(x: 50, y: 20).a, 0)
        XCTAssertEqual(bitmap.pixel(x: 50, y: 2), red.rgba8, "paint away from the stroke survives")
    }

    // MARK: - M6: opacity, hardness, pressure

    private func renderer(_ bitmap: Bitmap, _ configure: (inout BrushSettings) -> Void,
                          blendMode: CGBlendMode = .normal) -> StrokeRenderer {
        var settings = BrushSettings()
        configure(&settings)
        return StrokeRenderer(bitmap: bitmap, color: red, settings: settings, blendMode: blendMode)
    }

    /// A stroke that crosses itself many times stays at its opacity; it doesn't build up.
    func testOpacityIsCappedWithinAStroke() {
        let bitmap = Bitmap(width: 100, height: 40)
        let r = renderer(bitmap) { $0.size = 10; $0.opacity = 0.5 }
        _ = r.begin(at: CGPoint(x: 10, y: 20))
        for x in [90, 10, 90, 10] { _ = r.add(CGPoint(x: x, y: 20)) }
        _ = r.end()

        let p = bitmap.pixel(x: 50, y: 20)
        XCTAssertEqual(Int(p.a), 128, accuracy: 2, "50% stays 50% after 5 passes")
        XCTAssertEqual(p.r, 255)
    }

    func testSoftBrushFadesTowardTheEdge() {
        let bitmap = Bitmap(width: 100, height: 100)
        let r = renderer(bitmap) { $0.size = 40; $0.hardness = 0 }
        _ = r.begin(at: CGPoint(x: 50, y: 50))

        let center = Int(bitmap.pixel(x: 50, y: 50).a)
        let middle = Int(bitmap.pixel(x: 60, y: 50).a)  // halfway to the edge
        let rim = Int(bitmap.pixel(x: 68, y: 50).a)     // near the edge
        XCTAssertGreaterThan(center, 240)
        XCTAssertTrue(center > middle && middle > rim && rim > 0, "\(center) > \(middle) > \(rim) > 0")
        XCTAssertEqual(bitmap.pixel(x: 72, y: 50).a, 0, "nothing beyond the radius")
    }

    func testHardBrushIsSolidToTheEdge() {
        let bitmap = Bitmap(width: 100, height: 100)
        let r = renderer(bitmap) { $0.size = 40; $0.hardness = 1 }
        _ = r.begin(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(bitmap.pixel(x: 68, y: 50).a, 255)
        XCTAssertEqual(bitmap.pixel(x: 71, y: 50).a, 0)
    }

    func testPressureScalesSize() {
        let light = Bitmap(width: 100, height: 100)
        _ = renderer(light) { $0.size = 40 }.begin(at: CGPoint(x: 50, y: 50), pressure: 0.25)
        XCTAssertEqual(light.pixel(x: 58, y: 50).a, 0, "radius 20 × 0.25 = 5")
        XCTAssertEqual(light.pixel(x: 52, y: 50).a, 255)

        let ignored = Bitmap(width: 100, height: 100)
        _ = renderer(ignored) { $0.size = 40; $0.pressureControlsSize = false }
            .begin(at: CGPoint(x: 50, y: 50), pressure: 0.25)
        XCTAssertEqual(ignored.pixel(x: 58, y: 50).a, 255, "pressure ignored for size")
    }

    func testPressureScalesOpacity() {
        let bitmap = Bitmap(width: 100, height: 100)
        let r = renderer(bitmap) { $0.size = 20; $0.pressureControlsSize = false; $0.pressureControlsOpacity = true }
        _ = r.begin(at: CGPoint(x: 50, y: 50), pressure: 0.5)
        XCTAssertEqual(Int(bitmap.pixel(x: 50, y: 50).a), 128, accuracy: 2)
    }

    func testPressureIsInterpolatedAlongTheStroke() {
        let bitmap = Bitmap(width: 200, height: 60)
        let r = renderer(bitmap) { $0.size = 40 }
        _ = r.begin(at: CGPoint(x: 20, y: 30), pressure: 0.1)
        _ = r.add(CGPoint(x: 180, y: 30), pressure: 1)
        _ = r.end()
        // Thin at the start, thick at the end.
        XCTAssertEqual(bitmap.pixel(x: 30, y: 45).a, 0)
        XCTAssertEqual(bitmap.pixel(x: 175, y: 45).a, 255)
    }

    func testEraserRespectsOpacity() {
        let bitmap = Bitmap(width: 60, height: 40)
        bitmap.fill(red)
        let r = renderer(bitmap, { $0.size = 20; $0.opacity = 0.5 }, blendMode: .destinationOut)
        _ = r.begin(at: CGPoint(x: 30, y: 20))
        _ = r.add(CGPoint(x: 31, y: 20))
        _ = r.end()
        XCTAssertEqual(Int(bitmap.pixel(x: 30, y: 20).a), 128, accuracy: 2)
    }

    func testBigBrushIsFastEnough() {
        let bitmap = Bitmap(width: 1920, height: 1080)
        let r = renderer(bitmap) { $0.size = 200; $0.hardness = 0.5 }
        _ = r.begin(at: CGPoint(x: 100, y: 500))
        let start = Date()
        var x: CGFloat = 100
        while x < 1800 { x += 40; _ = r.add(CGPoint(x: x, y: 500)) } // ~42 drag events
        let perEvent = Date().timeIntervalSince(start) / 42
        XCTAssertLessThan(perEvent, 0.05, "\(Int(perEvent * 1000)) ms per drag event (Debug)")
    }
}
