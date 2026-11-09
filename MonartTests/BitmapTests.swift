import XCTest
@testable import Monart

final class BitmapTests: XCTestCase {
    func testNewBitmapIsTransparent() {
        let bitmap = Bitmap(width: 4, height: 3)
        for y in 0..<3 { for x in 0..<4 { XCTAssertEqual(bitmap.pixel(x: x, y: y), .clear) } }
    }

    func testDrawingUsesTopLeftOrigin() {
        let bitmap = Bitmap(width: 10, height: 10)
        bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), in: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), RGBA8(r: 255, g: 0, b: 0, a: 255))
        XCTAssertEqual(bitmap.pixel(x: 1, y: 1), RGBA8(r: 255, g: 0, b: 0, a: 255))
        XCTAssertEqual(bitmap.pixel(x: 0, y: 9), .clear)
        XCTAssertEqual(bitmap.pixel(x: 2, y: 0), .clear)
    }

    func testPixelIsUnpremultiplied() {
        let bitmap = Bitmap(width: 1, height: 1)
        bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        let p = bitmap.pixel(x: 0, y: 0)
        XCTAssertEqual(p.r, 255)
        XCTAssertEqual(p.g, 0)
        XCTAssertEqual(Int(p.a), 128, accuracy: 1)
    }

    func testOutOfBoundsPixelIsClear() {
        let bitmap = Bitmap(width: 2, height: 2)
        bitmap.fill(.white)
        XCTAssertEqual(bitmap.pixel(x: -1, y: 0), .clear)
        XCTAssertEqual(bitmap.pixel(x: 2, y: 0), .clear)
    }

    func testMakeImageCropMatchesCanvasCoordinates() throws {
        let bitmap = Bitmap(width: 10, height: 10)
        bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), in: CGRect(x: 0, y: 0, width: 5, height: 5))
        let image = try XCTUnwrap(bitmap.makeImage()?.cropping(to: CGRect(x: 0, y: 0, width: 5, height: 5)))

        // Redraw the crop into a fresh bitmap the way Compositor does and check it lands top-left.
        let target = Bitmap(width: 10, height: 10)
        target.context.drawUpright(image, in: CGRect(x: 0, y: 0, width: 5, height: 5))
        XCTAssertEqual(target.pixel(x: 0, y: 0).b, 255)
        XCTAssertEqual(target.pixel(x: 4, y: 4).b, 255)
        XCTAssertEqual(target.pixel(x: 0, y: 9), .clear)
    }

    func testPixelDataRoundTripIsExact() {
        let bitmap = Bitmap(width: 20, height: 20)
        bitmap.fill(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 0.37), in: CGRect(x: 3, y: 4, width: 9, height: 7))
        bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 1), in: CGRect(x: 8, y: 8, width: 5, height: 5))
        let rect = CGRect(x: 2, y: 3, width: 12, height: 11)
        let original = bitmap.pixelData(in: rect)
        XCTAssertEqual(original.count, 12 * 11 * 4)

        bitmap.clear()
        bitmap.setPixelData(original, in: rect)
        XCTAssertEqual(bitmap.pixelData(in: rect), original)
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), .clear, "pixels outside the rect untouched")
    }

    func testCopyContentsDuplicatesPixels() {
        let a = Bitmap(width: 8, height: 8)
        a.fill(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5), in: CGRect(x: 1, y: 2, width: 3, height: 3))
        let b = Bitmap(width: 8, height: 8)
        b.fill(.white)
        b.copyContents(of: a)
        XCTAssertEqual(b.pixelData(in: b.bounds), a.pixelData(in: a.bounds))
    }

    func testSetPixelDataAfterMakeImageDoesNotChangeEarlierImage() throws {
        let bitmap = Bitmap(width: 4, height: 4)
        bitmap.fill(.white)
        let snapshotImage = try XCTUnwrap(bitmap.makeImage())
        let red = Bitmap(width: 4, height: 4)
        red.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.setPixelData(red.pixelData(in: red.bounds), in: bitmap.bounds)

        let check = Bitmap(width: 4, height: 4)
        check.replace(with: snapshotImage, in: check.bounds)
        XCTAssertEqual(check.pixel(x: 1, y: 1), RGBA8(r: 255, g: 255, b: 255, a: 255))
        XCTAssertEqual(bitmap.pixel(x: 1, y: 1), RGBA8(r: 255, g: 0, b: 0, a: 255))
    }
}
