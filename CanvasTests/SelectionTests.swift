import XCTest
@testable import Canvas

final class SelectionTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func rect(_ r: CGRect, _ w: Int = 100, _ h: Int = 100) -> Selection {
        Selection.shape(CGPath(rect: r, transform: nil), width: w, height: h)!
    }

    // MARK: Model

    func testRectangleSelectionHasExactBoundsAndCoverage() {
        let s = rect(CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(s.bounds, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(s.coverage(x: 10, y: 20), 255)
        XCTAssertEqual(s.coverage(x: 39, y: 59), 255)
        XCTAssertEqual(s.coverage(x: 40, y: 20), 0)
        XCTAssertEqual(s.coverage(x: 9, y: 20), 0, "top-left origin, no flip")
    }

    func testEllipseHasSoftEdges() {
        let s = Selection.shape(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil),
                                width: 60, height: 60)!
        XCTAssertEqual(s.coverage(x: 25, y: 25), 255)
        XCTAssertEqual(s.coverage(x: 2, y: 2), 0)
        let edge = (0..<50).map { Int(s.coverage(x: $0, y: 25)) }.filter { $0 > 0 && $0 < 255 }
        XCTAssertFalse(edge.isEmpty, "antialiased rim")
    }

    func testEmptyShapeIsNoSelection() {
        XCTAssertNil(Selection.shape(CGPath(rect: .zero, transform: nil), width: 10, height: 10))
    }

    func testCombineModes() {
        let a = rect(CGRect(x: 0, y: 0, width: 50, height: 100))
        let b = rect(CGRect(x: 25, y: 0, width: 50, height: 100))

        XCTAssertEqual(b.combined(with: a, mode: .add)?.bounds, CGRect(x: 0, y: 0, width: 75, height: 100))
        XCTAssertEqual(b.combined(with: a, mode: .subtract)?.bounds, CGRect(x: 0, y: 0, width: 25, height: 100))
        XCTAssertEqual(b.combined(with: a, mode: .intersect)?.bounds, CGRect(x: 25, y: 0, width: 25, height: 100))
        XCTAssertEqual(b.combined(with: a, mode: .replace)?.bounds, b.bounds)
        XCTAssertNil(a.combined(with: a, mode: .subtract), "subtracting everything leaves nothing")
        XCTAssertNil(b.combined(with: nil, mode: .subtract))
        XCTAssertEqual(b.combined(with: nil, mode: .add)?.bounds, b.bounds)
    }

    func testInvert() {
        let s = rect(CGRect(x: 0, y: 0, width: 100, height: 40)).inverted()
        XCTAssertEqual(s?.bounds, CGRect(x: 0, y: 40, width: 100, height: 60))
        XCTAssertNil(Selection.all(width: 10, height: 10).inverted())
    }

    func testOutlineTracesTheBoundary() {
        let s = rect(CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(s.outline.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testTransformedMovesTheMask() {
        let s = rect(CGRect(x: 0, y: 0, width: 10, height: 10))
        let moved = s.transformed(CGAffineTransform(translationX: 30, y: 20))
        XCTAssertEqual(moved?.bounds, CGRect(x: 30, y: 20, width: 10, height: 10))
    }

    // MARK: Tools stay inside the selection

    private func paintContext() -> (CanvasModel, EditorState, HistoryManager, UndoManager) {
        let model = CanvasModel(width: 100, height: 100, background: nil)
        let editor = EditorState()
        editor.primaryColor = red
        let history = HistoryManager()
        let undo = UndoManager()
        undo.groupsByEvent = false
        history.undoManager = undo
        return (model, editor, history, undo)
    }

    func testBrushIsClippedToTheSelection() {
        let (model, editor, history, undo) = paintContext()
        model.selection = rect(CGRect(x: 0, y: 0, width: 50, height: 100))
        editor.brush.size = 10
        let context = ToolContext(model: model, editor: editor, history: history)
        let brush = BrushTool()
        undo.beginUndoGrouping()
        _ = brush.begin(ToolEvent(location: CGPoint(x: 10, y: 50), pressure: 1, modifiers: []), context: context)
        _ = brush.drag(ToolEvent(location: CGPoint(x: 90, y: 50), pressure: 1, modifiers: []), context: context)
        _ = brush.end(ToolEvent(location: CGPoint(x: 90, y: 50), pressure: 1, modifiers: []), context: context)
        undo.endUndoGrouping()
        let bitmap = model.layers[0].bitmap
        XCTAssertEqual(bitmap.pixel(x: 30, y: 50), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 70, y: 50), .clear)
    }

    func testFillAndShapesAreClipped() {
        let (model, editor, history, undo) = paintContext()
        model.selection = rect(CGRect(x: 0, y: 0, width: 50, height: 100))
        let context = ToolContext(model: model, editor: editor, history: history)
        undo.beginUndoGrouping()
        _ = FillTool().begin(ToolEvent(location: CGPoint(x: 5, y: 5), pressure: 1, modifiers: []), context: context)
        undo.endUndoGrouping()
        XCTAssertEqual(model.layers[0].bitmap.pixel(x: 49, y: 5), red.rgba8)
        XCTAssertEqual(model.layers[0].bitmap.pixel(x: 51, y: 5), .clear)

        let layer = model.addLayer()
        editor.shapeFilled = true
        let shape = ShapeTool(shape: .rectangle)
        undo.beginUndoGrouping()
        _ = shape.begin(ToolEvent(location: CGPoint(x: 20, y: 20), pressure: 1, modifiers: []), context: context)
        _ = shape.end(ToolEvent(location: CGPoint(x: 80, y: 80), pressure: 1, modifiers: []), context: context)
        undo.endUndoGrouping()
        XCTAssertEqual(layer.bitmap.pixel(x: 40, y: 40), red.rgba8)
        XCTAssertEqual(layer.bitmap.pixel(x: 60, y: 40), .clear)
    }

    func testSelectToolCombinesWithModifiers() {
        let (model, editor, history, _) = paintContext()
        let context = ToolContext(model: model, editor: editor, history: history)
        let tool = SelectTool()
        func drag(_ a: CGPoint, _ b: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            _ = tool.begin(ToolEvent(location: a, pressure: 1, modifiers: mods), context: context)
            _ = tool.drag(ToolEvent(location: b, pressure: 1, modifiers: mods), context: context)
            _ = tool.end(ToolEvent(location: b, pressure: 1, modifiers: mods), context: context)
        }
        drag(CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 40))
        XCTAssertEqual(model.selection?.bounds, CGRect(x: 0, y: 0, width: 40, height: 40))
        drag(CGPoint(x: 60, y: 60), CGPoint(x: 80, y: 80), .shift)
        XCTAssertEqual(model.selection?.bounds, CGRect(x: 0, y: 0, width: 80, height: 80))
        drag(CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 100), .option)
        XCTAssertEqual(model.selection?.bounds, CGRect(x: 0, y: 0, width: 40, height: 40))

        // A click without dragging deselects.
        _ = tool.begin(ToolEvent(location: CGPoint(x: 5, y: 5), pressure: 1, modifiers: []), context: context)
        _ = tool.end(ToolEvent(location: CGPoint(x: 5, y: 5), pressure: 1, modifiers: []), context: context)
        XCTAssertNil(model.selection)
    }

    func testMagicWandSelectsSimilarConnectedPixels() {
        let (model, editor, history, _) = paintContext()
        model.layers[0].bitmap.fill(red, in: CGRect(x: 0, y: 0, width: 30, height: 30))
        let context = ToolContext(model: model, editor: editor, history: history)
        _ = MagicWandTool().begin(ToolEvent(location: CGPoint(x: 5, y: 5), pressure: 1, modifiers: []), context: context)
        XCTAssertEqual(model.selection?.bounds, CGRect(x: 0, y: 0, width: 30, height: 30))
    }

    // MARK: Edits & clipboard

    func testClearSelectionIsUndoable() {
        let (model, _, history, undo) = paintContext()
        model.layers[0].bitmap.fill(red)
        model.selection = rect(CGRect(x: 0, y: 0, width: 50, height: 100))
        undo.beginUndoGrouping()
        PixelEdits.clearSelection(model: model, history: history)
        undo.endUndoGrouping()
        XCTAssertEqual(model.layers[0].bitmap.pixel(x: 10, y: 10), .clear)
        XCTAssertEqual(model.layers[0].bitmap.pixel(x: 60, y: 10), red.rgba8)
        undo.undo()
        XCTAssertEqual(model.layers[0].bitmap.pixel(x: 10, y: 10), red.rgba8)
    }

    func testCopyThenPasteRestoresPixelsAtTheSamePlaceOnANewLayer() throws {
        let (model, _, history, undo) = paintContext()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hunter.canvas.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        model.layers[0].bitmap.fill(red, in: CGRect(x: 20, y: 30, width: 10, height: 10))
        model.selection = rect(CGRect(x: 15, y: 25, width: 20, height: 20))

        XCTAssertTrue(PixelEdits.copy(model: model, to: pasteboard))
        let copied = try XCTUnwrap(PixelEdits.copiedImage(model: model))
        XCTAssertEqual(copied.image.width, 20, "cropped to the selection")
        XCTAssertEqual(copied.origin, CGPoint(x: 15, y: 25))

        undo.beginUndoGrouping()
        XCTAssertTrue(PixelEdits.paste(into: model, history: history, from: pasteboard))
        undo.endUndoGrouping()
        XCTAssertEqual(model.layers.count, 2)
        let pasted = model.layers[1]
        XCTAssertEqual(pasted.name, "Pasted")
        XCTAssertEqual(pasted.bitmap.pixel(x: 25, y: 35), red.rgba8, "same place as the original")
        XCTAssertEqual(pasted.bitmap.pixel(x: 50, y: 50), .clear)
        XCTAssertNil(model.selection)

        undo.undo()
        XCTAssertEqual(model.layers.count, 1)
    }

    func testPasteFromAnotherAppIsCentered() throws {
        let (model, _, history, undo) = paintContext()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hunter.canvas.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let source = Bitmap(width: 10, height: 10)
        source.fill(red)
        pasteboard.clearContents()
        pasteboard.setData(try DocumentFormat.pngData(XCTUnwrap(source.makeImage())), forType: .png)

        undo.beginUndoGrouping()
        XCTAssertTrue(PixelEdits.paste(into: model, history: history, from: pasteboard))
        undo.endUndoGrouping()
        XCTAssertEqual(model.layers[1].bitmap.pixel(x: 50, y: 50), red.rgba8)
        XCTAssertEqual(model.layers[1].bitmap.pixel(x: 44, y: 50), .clear)
    }

    func testOutlineOfALargeSelectionIsQuick() {
        let s = Selection.shape(CGPath(ellipseIn: CGRect(x: 100, y: 100, width: 1500, height: 800), transform: nil),
                                width: 1920, height: 1080)!
        let start = Date()
        _ = s.outline
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

final class MagicWandEdgeTests: XCTestCase {
    func testWandIncludesTheSoftEdgeOfAShapeButNotOpaqueNeighbours() {
        let model = CanvasModel(width: 60, height: 60, background: nil)
        let bitmap = model.layers[0].bitmap
        // An antialiased disc: solid center, partly transparent rim.
        bitmap.context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        bitmap.context.fillEllipse(in: CGRect(x: 10.3, y: 10.3, width: 30, height: 30))
        let context = ToolContext(model: model, editor: EditorState(), history: HistoryManager())
        _ = MagicWandTool().begin(ToolEvent(location: CGPoint(x: 25, y: 25), pressure: 1, modifiers: []), context: context)
        let selection = try! XCTUnwrap(model.selection)
        for y in 0..<60 {
            for x in 0..<60 where bitmap.pixel(x: x, y: y).a > 0 {
                XCTAssertEqual(selection.coverage(x: x, y: y), 255, "painted pixel (\(x),\(y)) left out")
            }
        }

        // On an opaque layer, a neighbouring color is not grabbed.
        let opaque = CanvasModel(width: 20, height: 10, background: nil)
        opaque.layers[0].bitmap.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        opaque.layers[0].bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), in: CGRect(x: 10, y: 0, width: 10, height: 10))
        let opaqueContext = ToolContext(model: opaque, editor: EditorState(), history: HistoryManager())
        _ = MagicWandTool().begin(ToolEvent(location: CGPoint(x: 2, y: 2), pressure: 1, modifiers: []), context: opaqueContext)
        XCTAssertEqual(opaque.selection?.bounds, CGRect(x: 0, y: 0, width: 10, height: 10))
    }
}

final class ImageLayerTests: XCTestCase {
    func testDroppedImageIsCenteredOnTheDropPoint() {
        let model = CanvasModel(width: 100, height: 100, background: nil)
        let image = Bitmap(width: 10, height: 10)
        image.fill(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        PixelEdits.addImageLayer(image.makeImage()!, centeredAt: CGPoint(x: 70, y: 30), name: "Photo",
                                 model: model, history: HistoryManager(), actionName: "Drop Image")
        let layer = model.layers[1]
        XCTAssertEqual(layer.name, "Photo")
        XCTAssertEqual(model.activeLayerID, layer.id)
        XCTAssertEqual(TransformSession.contentBounds(of: layer.bitmap), CGRect(x: 65, y: 25, width: 10, height: 10))
    }

    func testImagesBiggerThanTheCanvasAreShrunkToFit() {
        let model = CanvasModel(width: 100, height: 50, background: nil)
        let big = Bitmap(width: 400, height: 400)
        big.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        PixelEdits.addImageLayer(big.makeImage()!, centeredAt: nil, name: "Big",
                                 model: model, history: HistoryManager(), actionName: "Paste")
        XCTAssertEqual(TransformSession.contentBounds(of: model.layers[1].bitmap), CGRect(x: 25, y: 0, width: 50, height: 50),
                       "400×400 into 100×50 → 50×50, centered, not cropped")
    }

    /// Finder's copy puts the file's URL *and* its icon (as TIFF) on the pasteboard;
    /// paste must use the file, not the icon.
    func testCopiedFileFromFinderPastesTheFileNotItsIcon() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = Bitmap(width: 30, height: 20)
        photo.fill(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        let url = dir.appendingPathComponent("Holiday.png")
        try DocumentFormat.pngData(XCTUnwrap(photo.makeImage())).write(to: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hunter.canvas.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL, icon])

        let pasted = try XCTUnwrap(ImageImporter.image(from: pasteboard))
        XCTAssertEqual(pasted.image.width, 30)
        XCTAssertEqual(pasted.image.height, 20)
        XCTAssertEqual(pasted.name, "Holiday")
        XCTAssertTrue(ImageImporter.canRead(pasteboard))

        let model = CanvasModel(width: 100, height: 100, background: nil)
        XCTAssertTrue(PixelEdits.paste(into: model, history: HistoryManager(), from: pasteboard))
        XCTAssertEqual(model.layers[1].name, "Holiday")
        XCTAssertEqual(model.layers[1].bitmap.pixel(x: 50, y: 50).g, 255)

        // A copied file that isn't an image pastes nothing (not its icon).
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: text)
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSURL, NSWorkspace.shared.icon(forFile: text.path)])
        XCTAssertNil(ImageImporter.image(from: pasteboard))
        XCTAssertFalse(ImageImporter.canRead(pasteboard))
    }
}
