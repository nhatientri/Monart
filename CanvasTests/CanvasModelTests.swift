import XCTest
@testable import Canvas

final class CanvasModelTests: XCTestCase {
    private func names(_ model: CanvasModel) -> [String] { model.layers.map(\.name) }

    /// A model with layers A, B, C (bottom → top) and B active.
    private func makeABC() -> CanvasModel {
        let model = CanvasModel(width: 8, height: 8)
        model.layers[0].name = "A"
        model.addLayer().name = "B"
        model.addLayer().name = "C"
        model.activeLayerID = model.layers[1].id
        return model
    }

    func testAddLayerInsertsAboveActiveAndSelectsIt() {
        let model = makeABC()
        let new = model.addLayer()
        XCTAssertEqual(names(model), ["A", "B", new.name, "C"])
        XCTAssertEqual(model.activeLayerID, new.id)
        XCTAssertEqual(new.name, "Layer 4")
    }

    func testRemoveLayerSelectsLayerBelow() {
        let model = makeABC()
        model.removeLayer(model.layers[1].id)
        XCTAssertEqual(names(model), ["A", "C"])
        XCTAssertEqual(model.activeLayer?.name, "A")

        model.activeLayerID = model.layers[0].id
        model.removeLayer(model.layers[0].id)
        XCTAssertEqual(names(model), ["C"])
        XCTAssertEqual(model.activeLayer?.name, "C", "removing the bottom selects the new bottom")
    }

    func testCannotRemoveLastLayer() {
        let model = CanvasModel(width: 8, height: 8)
        XCTAssertFalse(model.canRemoveLayer)
        model.removeLayer(model.layers[0].id)
        XCTAssertEqual(model.layers.count, 1)
    }

    func testDuplicateCopiesPixelsAndProperties() throws {
        let model = makeABC()
        let source = model.layers[1]
        source.opacity = 0.4
        source.isVisible = false
        source.bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), in: CGRect(x: 1, y: 1, width: 2, height: 2))

        let copy = try XCTUnwrap(model.duplicateLayer(source.id))
        XCTAssertEqual(names(model), ["A", "B", "B copy", "C"])
        XCTAssertEqual(model.activeLayerID, copy.id)
        XCTAssertEqual(copy.opacity, 0.4)
        XCTAssertFalse(copy.isVisible)
        XCTAssertEqual(copy.bitmap.pixelData(in: copy.bitmap.bounds), source.bitmap.pixelData(in: source.bitmap.bounds))
        XCTAssertFalse(copy.bitmap === source.bitmap, "copy owns its own pixels")
    }

    func testMoveLayerByDeltaClamps() {
        let model = makeABC()
        let b = model.layers[1].id
        model.moveLayer(b, by: 1)
        XCTAssertEqual(names(model), ["A", "C", "B"])
        model.moveLayer(b, by: 5)
        XCTAssertEqual(names(model), ["A", "C", "B"])
        model.moveLayer(b, by: -10)
        XCTAssertEqual(names(model), ["B", "A", "C"])
    }

    func testMoveLayersUsesDisplayOrder() {
        // Display order (top first) is C, B, A. Drag A (display row 2) to the top (offset 0).
        let model = makeABC()
        model.moveLayers(fromDisplayOffsets: [2], toDisplayOffset: 0)
        XCTAssertEqual(names(model), ["B", "C", "A"])

        // Drag the top row (A) to the very bottom (offset 3 = after the last row).
        model.moveLayers(fromDisplayOffsets: [0], toDisplayOffset: 3)
        XCTAssertEqual(names(model), ["A", "B", "C"])
    }

    func testFlattenRespectsOrderVisibilityAndOpacity() throws {
        let model = CanvasModel(width: 4, height: 4, background: nil)
        model.layers[0].bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let top = model.addLayer()
        top.bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))

        func pixel() throws -> RGBA8 {
            let image = try XCTUnwrap(Compositor.flatten(model))
            let check = Bitmap(width: 4, height: 4)
            check.replace(with: image, in: check.bounds)
            return check.pixel(x: 1, y: 1)
        }

        XCTAssertEqual(try pixel(), RGBA8(r: 0, g: 0, b: 255, a: 255), "top layer covers bottom")

        top.opacity = 0.5
        let blended = try pixel()
        XCTAssertEqual(Int(blended.r), 128, accuracy: 2)
        XCTAssertEqual(Int(blended.b), 128, accuracy: 2)

        top.isVisible = false
        XCTAssertEqual(try pixel(), RGBA8(r: 255, g: 0, b: 0, a: 255), "hidden layer is skipped")

        model.moveLayer(top.id, by: -1)
        top.isVisible = true
        top.opacity = 1
        XCTAssertEqual(try pixel(), RGBA8(r: 255, g: 0, b: 0, a: 255), "reordered below, now covered")
    }

    func testThumbnailFitsWithinMaxSize() throws {
        let bitmap = Bitmap(width: 1920, height: 1080)
        let thumb = try XCTUnwrap(bitmap.makeThumbnail(maxPixelSize: 96))
        XCTAssertEqual(thumb.width, 96)
        XCTAssertEqual(thumb.height, 54)
    }
}

final class BlendModeTests: XCTestCase {
    private func flattenedPixel(_ mode: LayerBlendMode, top: CGColor, bottom: CGColor) throws -> RGBA8 {
        let model = CanvasModel(width: 4, height: 4, background: nil)
        model.layers[0].bitmap.fill(bottom)
        let layer = model.addLayer()
        layer.bitmap.fill(top)
        layer.blendMode = mode
        let image = try XCTUnwrap(Compositor.flatten(model))
        let check = Bitmap(width: 4, height: 4)
        check.replace(with: image, in: check.bounds)
        return check.pixel(x: 1, y: 1)
    }

    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    func testMultiplyDarkens() throws {
        XCTAssertEqual(try flattenedPixel(.multiply, top: blue, bottom: red), RGBA8(r: 0, g: 0, b: 0, a: 255))
    }

    func testScreenLightens() throws {
        XCTAssertEqual(try flattenedPixel(.screen, top: blue, bottom: red), RGBA8(r: 255, g: 0, b: 255, a: 255))
    }

    func testDifference() throws {
        let p = try flattenedPixel(.difference, top: gray, bottom: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(Int(p.r), 127, accuracy: 2)
    }

    func testDuplicateKeepsBlendMode() throws {
        let model = CanvasModel(width: 4, height: 4)
        model.layers[0].blendMode = .overlay
        let copy = try XCTUnwrap(model.duplicateLayer(model.layers[0].id))
        XCTAssertEqual(copy.blendMode, .overlay)
    }
}
