import ImageIO
import XCTest
@testable import Monart

final class ImageIOTests: XCTestCase {
    private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testPNGExportRoundTripsThroughImporter() throws {
        let model = CanvasModel(width: 40, height: 30, background: nil)
        model.layers[0].bitmap.fill(green, in: CGRect(x: 0, y: 0, width: 10, height: 10))

        let data = try ImageExporter.encode(model, as: .png)
        let image = try decode(data)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)

        let imported = try ImageImporter.makeModel(from: data)
        XCTAssertEqual(imported.width, 40)
        XCTAssertEqual(imported.height, 30)
        XCTAssertNil(imported.background)
        let bitmap = imported.layers[0].bitmap
        XCTAssertEqual(bitmap.pixel(x: 2, y: 2), green.rgba8, "top-left stays top-left")
        XCTAssertEqual(bitmap.pixel(x: 30, y: 25).a, 0, "transparency survives PNG")
    }

    func testExportIncludesBackgroundAndHiddenLayersAreSkipped() throws {
        let model = CanvasModel(width: 10, height: 10, background: .white)
        model.layers[0].bitmap.fill(green)
        model.layers[0].isVisible = false

        let imported = try ImageImporter.makeModel(from: ImageExporter.encode(model, as: .png))
        XCTAssertEqual(imported.layers[0].bitmap.pixel(x: 5, y: 5), RGBA8(r: 255, g: 255, b: 255, a: 255))
    }

    func testJPEGExportIsOpaqueOverWhite() throws {
        let model = CanvasModel(width: 16, height: 16, background: nil)
        let data = try ImageExporter.encode(model, as: .jpeg, jpegQuality: 0.8)
        let imported = try ImageImporter.makeModel(from: data)
        let p = imported.layers[0].bitmap.pixel(x: 8, y: 8)
        XCTAssertEqual(p.a, 255)
        XCTAssertGreaterThan(p.r, 245, "transparent areas become white, not black")
    }

    func testGarbageDataIsRejected() {
        XCTAssertThrowsError(try ImageImporter.makeModel(from: Data("not an image".utf8)))
    }
}
