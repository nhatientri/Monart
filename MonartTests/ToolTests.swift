import XCTest
@testable import Monart

final class ToolTests: XCTestCase {
    private var model: CanvasModel!
    private var editor: EditorState!
    private var history: HistoryManager!
    private var undoManager: UndoManager!

    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    override func setUp() {
        model = CanvasModel(width: 100, height: 100)
        editor = EditorState()
        editor.primaryColor = red
        history = HistoryManager()
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        history.undoManager = undoManager
    }

    private var context: ToolContext { ToolContext(model: model, editor: editor, history: history) }
    private var layer: Layer { model.activeLayer! }

    private func event(_ x: CGFloat, _ y: CGFloat, _ modifiers: NSEvent.ModifierFlags = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), pressure: 1, modifiers: modifiers)
    }

    /// Runs one press-drag-release inside its own undo group.
    @discardableResult
    private func drag(_ tool: Tool, from a: CGPoint, to b: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) -> CGRect {
        undoManager.beginUndoGrouping()
        var dirty = tool.begin(event(a.x, a.y, modifiers), context: context)
        dirty = dirty.union(tool.drag(event(b.x, b.y, modifiers), context: context))
        dirty = dirty.union(tool.end(event(b.x, b.y, modifiers), context: context))
        undoManager.endUndoGrouping()
        return dirty
    }

    // MARK: Shapes

    func testShiftConstrainsLineTo45Degrees() {
        let end = ShapeTool.endPoint(for: .line, from: .zero, to: CGPoint(x: 100, y: 10), constrained: true)
        XCTAssertEqual(end.x, 100.5, accuracy: 0.5)
        XCTAssertEqual(end.y, 0, accuracy: 0.001)

        let diagonal = ShapeTool.endPoint(for: .line, from: .zero, to: CGPoint(x: 50, y: 45), constrained: true)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }

    func testShiftConstrainsBoxToSquareKeepingDirection() {
        let end = ShapeTool.endPoint(for: .rectangle, from: CGPoint(x: 50, y: 50),
                                     to: CGPoint(x: 20, y: 60), constrained: true)
        XCTAssertEqual(end, CGPoint(x: 20, y: 80))
    }

    func testFilledRectangleCommitsAndUndoes() {
        editor.shapeFilled = true
        let tool = ShapeTool(shape: .rectangle)
        drag(tool, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 40))

        XCTAssertEqual(layer.bitmap.pixel(x: 20, y: 25), red.rgba8)
        XCTAssertEqual(layer.bitmap.pixel(x: 10, y: 10), red.rgba8)
        XCTAssertEqual(layer.bitmap.pixel(x: 30, y: 40), .clear, "exclusive far edge")
        XCTAssertEqual(undoManager.undoActionName, "Rectangle")

        undoManager.undo()
        XCTAssertEqual(layer.bitmap.pixel(x: 20, y: 25), .clear)
    }

    func testStrokedRectangleLeavesInteriorEmpty() {
        editor.shapeLineWidth = 1
        drag(ShapeTool(shape: .rectangle), from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(layer.bitmap.pixel(x: 10, y: 30), red.rgba8, "crisp 1 px edge on the pixel")
        XCTAssertEqual(layer.bitmap.pixel(x: 30, y: 30), .clear)
    }

    func testShapeDoesNotTouchLayerUntilMouseUp() {
        let tool = ShapeTool(shape: .line)
        _ = tool.begin(event(10, 10), context: context)
        let preview = tool.drag(event(80, 10), context: context)
        XCTAssertFalse(preview.isNull, "drag reports the preview area for redraw")
        XCTAssertEqual(layer.bitmap.pixel(x: 40, y: 10), .clear, "only a preview so far")
    }

    // MARK: Fill, eyedropper, text

    func testFillToolUsesToleranceAndIsUndoable() {
        undoManager.beginUndoGrouping()
        _ = FillTool().begin(event(5, 5), context: context)
        undoManager.endUndoGrouping()
        XCTAssertEqual(layer.bitmap.pixel(x: 99, y: 99), red.rgba8)
        undoManager.undo()
        XCTAssertEqual(layer.bitmap.pixel(x: 99, y: 99), .clear)
    }

    func testEyedropperSamplesCompositeIncludingBackground() {
        _ = EyedropperTool().begin(event(50, 50), context: context)
        XCTAssertEqual(editor.primaryColor.rgba8, RGBA8(r: 255, g: 255, b: 255, a: 255), "white background")

        let top = model.addLayer()
        top.bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        top.opacity = 0.5
        _ = EyedropperTool().begin(event(50, 50), context: context)
        let c = editor.primaryColor.rgba8
        XCTAssertEqual(Int(c.r), 128, accuracy: 2, "50% blue over white")
        XCTAssertEqual(c.b, 255)
    }

    func testEyedropperIgnoresTransparentPixels() {
        model.background = nil
        _ = EyedropperTool().begin(event(50, 50), context: context)
        XCTAssertEqual(editor.primaryColor.rgba8, red.rgba8, "unchanged")
    }

    func testTextRasterizesUprightInsideDirtyRect() {
        let font = NSFont.systemFont(ofSize: 40)
        undoManager.beginUndoGrouping()
        let dirty = TextTool.rasterize("_", at: CGPoint(x: 10, y: 10), font: font, color: red,
                                       into: layer, history: history)
        undoManager.endUndoGrouping()
        var inkRows: [Int] = []
        for y in 0..<100 {
            for x in 0..<100 where layer.bitmap.pixel(x: x, y: y).a > 128 {
                XCTAssertTrue(dirty.contains(CGPoint(x: x, y: y)), "ink at (\(x),\(y)) outside \(dirty)")
                inkRows.append(y)
            }
        }
        XCTAssertFalse(inkRows.isEmpty)
        // An underscore sits at the bottom of its line; upside-down text would put it near the top.
        let lineHeight = NSAttributedString(string: "_", attributes: [.font: font]).size().height
        XCTAssertGreaterThan(Double(inkRows.min()!), 10 + Double(lineHeight) / 2)
    }

    // MARK: Editor

    func testStepSizeTargetsCurrentTool() {
        editor.tool = .brush
        editor.brush.size = 10
        editor.stepSize(1)
        XCTAssertEqual(editor.brush.size, 15)
        editor.stepSize(-1)
        XCTAssertEqual(editor.brush.size, 10)
        editor.stepSize(-1)
        XCTAssertEqual(editor.brush.size, 9)

        editor.tool = .text
        editor.fontSize = 400
        editor.stepSize(1)
        XCTAssertEqual(editor.fontSize, 400, "clamped to range")
    }

    func testEveryToolHasAUniqueShortcut() {
        let keys = ToolKind.allCases.map(\.shortcut)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(ToolKind.paletteGroups.flatMap { $0 }), Set(ToolKind.allCases))
    }

    // MARK: Colors

    func testSwapColors() {
        editor.primaryColor = red
        editor.secondaryColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        editor.swapColors()
        XCTAssertEqual(editor.primaryColor.rgba8, RGBA8(r: 0, g: 0, b: 255, a: 255))
        XCTAssertEqual(editor.secondaryColor.rgba8, red.rgba8)
    }

    func testRecentColorsAreMostRecentFirstWithoutDuplicates() {
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        editor.primaryColor = red; editor.noteColorUsed()
        editor.primaryColor = blue; editor.noteColorUsed()
        editor.primaryColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1); editor.noteColorUsed()
        XCTAssertEqual(editor.recentColors.map(\.rgba8), [red.rgba8, blue.rgba8])
    }

    func testRecentColorsAreCapped() {
        for i in 0..<(EditorState.maxRecentColors + 5) {
            editor.primaryColor = CGColor(srgbRed: CGFloat(i) / 40, green: 0, blue: 0, alpha: 1)
            editor.noteColorUsed()
        }
        XCTAssertEqual(editor.recentColors.count, EditorState.maxRecentColors)
    }

    func testBrushCursorMatchesOnScreenSize() {
        let cursor = BrushCursor.cursor(diameter: 60)
        XCTAssertEqual(cursor.image.size.width, 64, accuracy: 1)
        XCTAssertEqual(cursor.hotSpot.x, cursor.image.size.width / 2)
        XCTAssertTrue(BrushCursor.cursor(diameter: 5000) === NSCursor.crosshair, "too big → crosshair")
    }
}
