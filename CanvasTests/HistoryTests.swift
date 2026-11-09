import XCTest
@testable import Canvas

final class HistoryTests: XCTestCase {
    private var undoManager: UndoManager!
    private var history: HistoryManager!
    private var layer: Layer!

    private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    override func setUp() {
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        history = HistoryManager()
        history.undoManager = undoManager
        layer = Layer(name: "Test", width: 64, height: 64)
    }

    /// Simulates one tool stroke: begin, paint a rect, commit — inside its own undo group.
    private func paint(_ rect: CGRect, _ color: CGColor, name: String = "Paint") {
        undoManager.beginUndoGrouping()
        history.beginEdit(on: layer)
        layer.bitmap.fill(color, in: rect)
        history.commit(dirtyRect: rect, actionName: name)
        undoManager.endUndoGrouping()
    }

    func testUndoRestoresAndRedoReapplies() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        paint(rect, blue, name: "Brush Stroke")
        XCTAssertEqual(layer.bitmap.pixel(x: 15, y: 15), blue.rgba8)
        XCTAssertEqual(undoManager.undoActionName, "Brush Stroke")

        undoManager.undo()
        XCTAssertEqual(layer.bitmap.pixel(x: 15, y: 15), .clear)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(layer.bitmap.pixel(x: 15, y: 15), blue.rgba8)
    }

    func testMultipleStepsUndoInOrder() {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        paint(CGRect(x: 0, y: 0, width: 32, height: 32), blue)
        paint(CGRect(x: 16, y: 16, width: 32, height: 32), red)
        XCTAssertEqual(layer.bitmap.pixel(x: 20, y: 20), red.rgba8)

        undoManager.undo()
        XCTAssertEqual(layer.bitmap.pixel(x: 20, y: 20), blue.rgba8, "overlap returns to the first stroke")
        XCTAssertEqual(layer.bitmap.pixel(x: 40, y: 40), .clear)

        undoManager.undo()
        XCTAssertEqual(layer.bitmap.pixel(x: 20, y: 20), .clear)
    }

    func testOnlyDirtyRectIsStored() {
        var restored: CGRect?
        history.onRestore = { _, rect in restored = rect }
        paint(CGRect(x: 5, y: 6, width: 7, height: 8), blue)
        undoManager.undo()
        XCTAssertEqual(restored, CGRect(x: 5, y: 6, width: 7, height: 8))
    }

    func testEmptyEditRegistersNothing() {
        undoManager.beginUndoGrouping()
        history.beginEdit(on: layer)
        history.commit(dirtyRect: .null, actionName: "Nothing")
        undoManager.endUndoGrouping()
        XCTAssertFalse(history.isEditing)
        undoManager.undo() // undoes the empty group
        XCTAssertFalse(undoManager.canUndo)
    }

    func testHistoryIsCapped() {
        XCTAssertEqual(undoManager.levelsOfUndo, HistoryManager.maxSteps)
        for i in 0..<(HistoryManager.maxSteps + 10) {
            paint(CGRect(x: i % 60, y: 0, width: 2, height: 2), blue)
        }
        var steps = 0
        while undoManager.canUndo { undoManager.undo(); steps += 1 }
        XCTAssertEqual(steps, HistoryManager.maxSteps)
    }

    // MARK: - Layer stack

    private func grouped(_ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private func layerChange(_ model: CanvasModel, _ name: String, _ change: () -> Void) {
        grouped { history.performLayerChange(in: model, actionName: name, change) }
    }

    func testUndoRedoAddLayer() {
        let model = CanvasModel(width: 16, height: 16)
        let original = model.layers[0]
        layerChange(model, "Add Layer") { model.addLayer() }
        XCTAssertEqual(model.layers.count, 2)
        XCTAssertEqual(undoManager.undoActionName, "Add Layer")

        undoManager.undo()
        XCTAssertEqual(model.layers.map(\.id), [original.id])
        XCTAssertEqual(model.activeLayerID, original.id, "selection is restored too")

        undoManager.redo()
        XCTAssertEqual(model.layers.count, 2)
    }

    func testUndoDeleteRestoresSameLayerWithPixels() {
        let model = CanvasModel(width: 16, height: 16)
        let painted = model.addLayer()
        painted.bitmap.fill(blue)
        layerChange(model, "Delete Layer") { model.removeLayer(painted.id) }
        XCTAssertEqual(model.layers.count, 1)

        undoManager.undo()
        XCTAssertTrue(model.layers.last === painted)
        XCTAssertEqual(model.activeLayerID, painted.id)
        XCTAssertEqual(painted.bitmap.pixel(x: 3, y: 3), blue.rgba8)
    }

    func testUndoReorder() {
        let model = CanvasModel(width: 16, height: 16)
        model.addLayer(); model.addLayer()
        let before = model.layers.map(\.id)
        layerChange(model, "Move Layer") { model.moveLayer(before[0], by: 2) }
        XCTAssertNotEqual(model.layers.map(\.id), before)
        undoManager.undo()
        XCTAssertEqual(model.layers.map(\.id), before)
    }

    func testNoOpLayerChangeRegistersNothing() {
        let model = CanvasModel(width: 16, height: 16)
        layerChange(model, "Move Layer") { model.moveLayer(model.layers[0].id, by: 1) } // only layer: no-op
        undoManager.undo() // pops the empty group
        XCTAssertFalse(undoManager.canUndo)
    }

    /// Paint on a layer, delete it, then undo both: the stroke undo must still find its layer.
    func testPixelUndoAfterDeleteAndRestore() {
        let model = CanvasModel(width: 64, height: 64)
        layer = model.addLayer()
        paint(CGRect(x: 0, y: 0, width: 8, height: 8), blue)
        let painted = layer!
        layerChange(model, "Delete Layer") { model.removeLayer(painted.id) }

        undoManager.undo() // delete
        undoManager.undo() // stroke
        XCTAssertTrue(model.layers.contains { $0 === painted })
        XCTAssertEqual(painted.bitmap.pixel(x: 2, y: 2), .clear)
    }

    func testPixelEditsBumpContentRevision() {
        let start = layer.contentRevision
        paint(CGRect(x: 0, y: 0, width: 4, height: 4), blue)
        XCTAssertEqual(layer.contentRevision, start + 1)
        undoManager.undo()
        XCTAssertEqual(layer.contentRevision, start + 2)
    }
}
