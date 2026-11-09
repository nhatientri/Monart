import XCTest
@testable import Monart

final class FilterTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private var model: CanvasModel!
    private var history: HistoryManager!
    private var undo: UndoManager!

    override func setUp() {
        model = CanvasModel(width: 60, height: 40, background: nil)
        history = HistoryManager()
        undo = UndoManager()
        undo.groupsByEvent = false
        history.undoManager = undo
        model.layers[0].bitmap.fill(red)
    }

    private var bitmap: Bitmap { model.layers[0].bitmap }

    private func apply(_ kind: FilterKind, _ p: FilterParameters = FilterParameters()) {
        undo.beginUndoGrouping()
        FilterSession(kind: kind, model: model, history: history)!.commit(p)
        undo.endUndoGrouping()
    }

    private func close(_ a: RGBA8, _ b: RGBA8, tolerance: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b), (a.a, b.a)] {
            XCTAssertEqual(Int(x), Int(y), accuracy: tolerance, "\(a) vs \(b)", file: file, line: line)
        }
    }

    func testInvertTurnsRedCyanAndIsUndoable() {
        apply(.invert)
        close(bitmap.pixel(x: 10, y: 10), RGBA8(r: 0, g: 255, b: 255, a: 255))
        XCTAssertEqual(undo.undoActionName, "Invert")
        undo.undo()
        XCTAssertEqual(bitmap.pixel(x: 10, y: 10), red.rgba8)
    }

    func testGrayscaleHasEqualChannels() {
        apply(.grayscale)
        let p = bitmap.pixel(x: 10, y: 10)
        XCTAssertEqual(Int(p.r), Int(p.g), accuracy: 2)
        XCTAssertEqual(Int(p.g), Int(p.b), accuracy: 2)
        XCTAssertGreaterThan(p.r, 20)
    }

    func testFilterStaysInsideTheSelection() {
        model.selection = Selection.shape(CGPath(rect: CGRect(x: 0, y: 0, width: 30, height: 40), transform: nil),
                                          width: 60, height: 40)
        apply(.invert)
        close(bitmap.pixel(x: 10, y: 10), RGBA8(r: 0, g: 255, b: 255, a: 255))
        XCTAssertEqual(bitmap.pixel(x: 50, y: 10), red.rgba8)
    }

    func testPreviewThenCancelRestoresTheLayer() {
        let before = bitmap.pixelData(in: bitmap.bounds)
        let session = FilterSession(kind: .hueSaturation, model: model, history: history)!
        var p = FilterParameters()
        p.hue = 120
        session.preview(p)
        XCTAssertNotEqual(bitmap.pixelData(in: bitmap.bounds), before, "preview shows on the layer")
        session.cancel()
        XCTAssertEqual(bitmap.pixelData(in: bitmap.bounds), before)
        XCTAssertFalse(undo.canUndo)
    }

    func testBlurSoftensEdgesButNotTheCanvasBorder() {
        bitmap.clear()
        bitmap.fill(red, in: CGRect(x: 0, y: 0, width: 30, height: 40))
        var p = FilterParameters()
        p.radius = 4
        apply(.gaussianBlur, p)
        let edge = bitmap.pixel(x: 30, y: 20).a
        XCTAssertTrue(edge > 40 && edge < 215, "soft edge at the paint boundary: \(edge)")
        XCTAssertGreaterThan(bitmap.pixel(x: 0, y: 0).a, 245, "no dark fringe at the canvas border")
    }

    func testPosterizeLimitsLevels() {
        bitmap.fill(CGColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1))
        var p = FilterParameters()
        p.levels = 2
        apply(.posterize, p)
        let v = bitmap.pixel(x: 5, y: 5).r
        XCTAssertTrue(v < 10 || v > 245, "two levels: black or white, got \(v)")
    }

    func testHiddenLayerCannotBeFiltered() {
        model.layers[0].isVisible = false
        XCTAssertNil(FilterSession(kind: .invert, model: model, history: history))
    }
}
