import XCTest
@testable import Monart

final class CanvasSizeTests: XCTestCase {
    private func documentWithUndo(_ model: CanvasModel) -> (CanvasDocument, UndoManager) {
        let document = CanvasDocument(model: model)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.history.undoManager = undoManager
        return (document, undoManager)
    }

    private func step(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    func testNewDocumentOpensOnADefaultCanvas() {
        let document = CanvasDocument(model: CanvasSetup().makeModel())
        XCTAssertEqual(document.model.width, 1920)
        XCTAssertEqual(document.model.height, 1080)
        XCTAssertNotNil(document.model.background)
        XCTAssertEqual(document.model.layers.count, 1)
    }

    func testSavedDefaultRoundTrips() {
        let defaults = UserDefaults(suiteName: "CanvasSizeTests-\(UUID())")!
        XCTAssertEqual(CanvasSetup.savedDefault(in: defaults), CanvasSetup(), "nothing saved → built-in default")
        var setup = CanvasSetup(width: 800, height: 600, background: .color)
        setup.color = [0.2, 0.4, 0.6]
        setup.saveAsDefault(in: defaults)
        XCTAssertEqual(CanvasSetup.savedDefault(in: defaults), setup)
    }

    func testSetupReadsTheCurrentBackground() {
        XCTAssertEqual(CanvasSetup(CanvasModel(width: 10, height: 10, background: .white)).background, .white)
        XCTAssertEqual(CanvasSetup(CanvasModel(width: 10, height: 10, background: nil)).background, .transparent)
        let colored = CanvasSetup(CanvasModel(width: 10, height: 10, background: red))
        XCTAssertEqual(colored.background, .color)
        XCTAssertEqual(colored.color[0], 1, accuracy: 0.01)
        XCTAssertEqual(colored.color[1], 0, accuracy: 0.01)
    }

    func testCropOrExtendKeepsPixelsCenteredAndUndoes() {
        let model = CanvasModel(width: 20, height: 10, background: nil)
        model.layers[0].bitmap.fill(red, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        model.layers[0].name = "Sky"
        model.layers[0].opacity = 0.5
        let id = model.layers[0].id
        let (document, undoManager) = documentWithUndo(model)

        step(undoManager) { document.changeCanvas(to: CanvasSetup(width: 40, height: 30, background: .white), mode: .keepPixels) }
        let resized = document.model
        XCTAssertEqual(resized.width, 40)
        XCTAssertEqual(resized.height, 30)
        XCTAssertNotNil(resized.background)
        XCTAssertEqual(resized.layers[0].id, id)
        XCTAssertEqual(resized.layers[0].name, "Sky")
        XCTAssertEqual(resized.layers[0].opacity, 0.5)
        XCTAssertEqual(resized.activeLayerID, id)
        XCTAssertEqual(resized.layers[0].bitmap.pixel(x: 10, y: 10).a, 255, "old (0,0) moves to the centered offset")
        XCTAssertEqual(resized.layers[0].bitmap.pixel(x: 0, y: 0).a, 0, "new space is transparent")

        undoManager.undo()
        XCTAssertTrue(document.model === model, "undo brings back the original canvas")
        undoManager.redo()
        XCTAssertTrue(document.model === resized)
    }

    func testShrinkingCropsAndScalingStretches() {
        let model = CanvasModel(width: 20, height: 20, background: nil)
        model.layers[0].bitmap.fill(red, in: CGRect(x: 0, y: 0, width: 10, height: 20))   // left half red
        let (document, undoManager) = documentWithUndo(model)

        step(undoManager) { document.changeCanvas(to: CanvasSetup(width: 10, height: 10, background: .transparent), mode: .keepPixels) }
        let cropped = document.model.layers[0].bitmap
        XCTAssertEqual(cropped.pixel(x: 4, y: 5).a, 255, "x 5…9 of the old canvas")
        XCTAssertEqual(cropped.pixel(x: 5, y: 5).a, 0)
        undoManager.undo()

        step(undoManager) { document.changeCanvas(to: CanvasSetup(width: 40, height: 10, background: .transparent), mode: .scaleImage) }
        let scaled = document.model.layers[0].bitmap
        XCTAssertEqual(scaled.pixel(x: 5, y: 5).a, 255)
        XCTAssertEqual(scaled.pixel(x: 18, y: 5).a, 255, "red now covers the left 20 px")
        XCTAssertEqual(scaled.pixel(x: 22, y: 5).a, 0)
    }

    func testBackgroundOnlyChangeKeepsTheCanvasAndUndoes() {
        let model = CanvasModel(width: 10, height: 10, background: .white)
        let (document, undoManager) = documentWithUndo(model)

        step(undoManager) { document.changeCanvas(to: CanvasSetup(width: 10, height: 10, background: .transparent), mode: .scaleImage) }
        XCTAssertTrue(document.model === model, "same size → no copy")
        XCTAssertNil(model.background)
        undoManager.undo()
        XCTAssertNotNil(model.background)
        undoManager.redo()
        XCTAssertNil(model.background)
    }

    func testNewLayerNamesContinueAfterResize() {
        let model = CanvasModel(width: 10, height: 10, background: nil)
        model.addLayer()   // Layer 2
        let (document, undoManager) = documentWithUndo(model)
        step(undoManager) { document.changeCanvas(to: CanvasSetup(width: 20, height: 20, background: .white), mode: .scaleImage) }
        XCTAssertEqual(document.model.addLayer().name, "Layer 3")
    }
}
