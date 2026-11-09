import XCTest
@testable import Canvas

final class FloodFillTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// A 20×20 bitmap with a 1 px black square outline from (5,5) to (14,14).
    private func makeBoxed() -> Bitmap {
        let bitmap = Bitmap(width: 20, height: 20)
        bitmap.fill(black, in: CGRect(x: 5, y: 5, width: 10, height: 1))
        bitmap.fill(black, in: CGRect(x: 5, y: 14, width: 10, height: 1))
        bitmap.fill(black, in: CGRect(x: 5, y: 5, width: 1, height: 10))
        bitmap.fill(black, in: CGRect(x: 14, y: 5, width: 1, height: 10))
        return bitmap
    }

    func testFillsInsideBoundaryOnly() {
        let bitmap = makeBoxed()
        let dirty = FloodFill.fill(bitmap, at: CGPoint(x: 9.5, y: 9.5), color: red, tolerance: 0)

        XCTAssertEqual(dirty, CGRect(x: 6, y: 6, width: 8, height: 8))
        XCTAssertEqual(bitmap.pixel(x: 6, y: 6), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 13, y: 13), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 5, y: 9), black.rgba8, "boundary untouched")
        XCTAssertEqual(bitmap.pixel(x: 2, y: 2), .clear, "outside untouched")
    }

    func testFillsOutsideAroundBoundary() {
        let bitmap = makeBoxed()
        FloodFill.fill(bitmap, at: CGPoint(x: 0, y: 0), color: red, tolerance: 0)
        XCTAssertEqual(bitmap.pixel(x: 19, y: 19), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 9, y: 9), .clear, "enclosed area untouched")
    }

    func testEmptyCanvasFillsEverything() {
        let bitmap = Bitmap(width: 30, height: 10)
        let dirty = FloodFill.fill(bitmap, at: CGPoint(x: 3, y: 3), color: red, tolerance: 0)
        XCTAssertEqual(dirty, bitmap.bounds)
        XCTAssertEqual(bitmap.pixel(x: 29, y: 9), red.rgba8)
    }

    func testToleranceControlsSpreading() {
        func makeTwoTone() -> Bitmap {
            let bitmap = Bitmap(width: 20, height: 10)
            bitmap.fill(CGColor(srgbRed: 100 / 255, green: 100 / 255, blue: 100 / 255, alpha: 1),
                        in: CGRect(x: 0, y: 0, width: 10, height: 10))
            bitmap.fill(CGColor(srgbRed: 110 / 255, green: 100 / 255, blue: 100 / 255, alpha: 1),
                        in: CGRect(x: 10, y: 0, width: 10, height: 10))
            return bitmap
        }
        let strict = makeTwoTone()
        FloodFill.fill(strict, at: CGPoint(x: 2, y: 2), color: red, tolerance: 5)
        XCTAssertEqual(strict.pixel(x: 15, y: 5).r, 110, "difference of 10 > tolerance 5")

        let loose = makeTwoTone()
        FloodFill.fill(loose, at: CGPoint(x: 2, y: 2), color: red, tolerance: 20)
        XCTAssertEqual(loose.pixel(x: 15, y: 5), red.rgba8, "difference of 10 ≤ tolerance 20")
    }

    /// Semi-transparent paint of one color is one region even though its stored bytes differ
    /// from the opaque version of the color — comparison is un-premultiplied.
    func testComparesUnpremultipliedColors() {
        let bitmap = Bitmap(width: 10, height: 10)
        bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        let region = FloodFill.region(in: bitmap, seedX: 0, seedY: 0, tolerance: 0)
        XCTAssertEqual(region?.bounds, bitmap.bounds)
    }

    func testDiagonalGapDoesNotLeak() {
        // 4-way fill: a diagonal line of pixels is a wall.
        let bitmap = Bitmap(width: 10, height: 10)
        for i in 0..<10 { bitmap.fill(black, in: CGRect(x: i, y: 9 - i, width: 1, height: 1)) }
        FloodFill.fill(bitmap, at: CGPoint(x: 0, y: 0), color: red, tolerance: 0)
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 9, y: 9), .clear)
    }

    func testSeedOutsideBitmapDoesNothing() {
        let bitmap = Bitmap(width: 10, height: 10)
        XCTAssertEqual(FloodFill.fill(bitmap, at: CGPoint(x: -1, y: 4), color: red, tolerance: 0), .null)
        XCTAssertEqual(FloodFill.fill(bitmap, at: CGPoint(x: 10, y: 4), color: red, tolerance: 0), .null)
    }

    func testLargeFillIsReasonablyFast() {
        let bitmap = Bitmap(width: 1920, height: 1080)
        measure {
            FloodFill.fill(bitmap, at: CGPoint(x: 5, y: 5), color: red, tolerance: 30)
        }
    }
}
