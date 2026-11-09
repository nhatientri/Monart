import XCTest
@testable import Canvas

final class TransformTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private var model: CanvasModel!
    private var history: HistoryManager!
    private var undo: UndoManager!

    override func setUp() {
        model = CanvasModel(width: 100, height: 100, background: nil)
        history = HistoryManager()
        undo = UndoManager()
        undo.groupsByEvent = false
        history.undoManager = undo
        // A 10×10 red square at (10, 10).
        model.layers[0].bitmap.fill(red, in: CGRect(x: 10, y: 10, width: 10, height: 10))
    }

    private var bitmap: Bitmap { model.layers[0].bitmap }
    private var context: ToolContext { ToolContext(model: model, editor: EditorState(), history: history) }

    private func grouped(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func testMoveWholeLayerWhenNothingIsSelected() {
        let tool = MoveTool()
        grouped {
            _ = tool.begin(ToolEvent(location: CGPoint(x: 15, y: 15), pressure: 1, modifiers: []), context: context)
            _ = tool.drag(ToolEvent(location: CGPoint(x: 45, y: 35), pressure: 1, modifiers: []), context: context)
            _ = tool.end(ToolEvent(location: CGPoint(x: 45, y: 35), pressure: 1, modifiers: []), context: context)
        }
        XCTAssertEqual(bitmap.pixel(x: 15, y: 15), .clear, "old spot is empty")
        XCTAssertEqual(bitmap.pixel(x: 45, y: 35), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 40, y: 30), red.rgba8, "crisp: exact color at the moved corner")
        XCTAssertEqual(undo.undoActionName, "Move")

        undo.undo()
        XCTAssertEqual(bitmap.pixel(x: 15, y: 15), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 45, y: 35), .clear)
    }

    func testMoveOnlyTheSelectionAndTheSelectionFollows() {
        model.selection = Selection.shape(CGPath(rect: CGRect(x: 10, y: 10, width: 5, height: 10), transform: nil),
                                          width: 100, height: 100)
        let session = TransformSession(model: model, history: history)!
        grouped {
            session.apply(CGAffineTransform(translationX: 50, y: 0))
            session.commit(actionName: "Move")
        }
        XCTAssertEqual(bitmap.pixel(x: 12, y: 15), .clear, "selected half moved away")
        XCTAssertEqual(bitmap.pixel(x: 17, y: 15), red.rgba8, "unselected half stays")
        XCTAssertEqual(bitmap.pixel(x: 62, y: 15), red.rgba8)
        XCTAssertEqual(model.selection?.bounds, CGRect(x: 60, y: 10, width: 5, height: 10))
    }

    func testScaleDoublesTheSize() {
        let session = TransformSession(model: model, history: history)!
        XCTAssertEqual(session.sourceRect, CGRect(x: 10, y: 10, width: 10, height: 10), "the painted area")
        // Scale 2× around the square's top-left corner.
        let t = CGAffineTransform(translationX: 10, y: 10).scaledBy(x: 2, y: 2).translatedBy(x: -10, y: -10)
        grouped {
            session.apply(t)
            session.commit(actionName: "Free Transform")
        }
        XCTAssertEqual(bitmap.pixel(x: 28, y: 28), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 31, y: 31), .clear)
    }

    func testCancelRestoresEverything() {
        let before = bitmap.pixelData(in: bitmap.bounds)
        let session = TransformSession(model: model, history: history)!
        session.apply(CGAffineTransform(rotationAngle: 0.7))
        session.cancel()
        XCTAssertEqual(bitmap.pixelData(in: bitmap.bounds), before)
        XCTAssertFalse(undo.canUndo)
    }

    func testNothingToTransform() {
        model.layers[0].bitmap.clear()
        XCTAssertNil(TransformSession(model: model, history: history), "empty layer")
        model.layers[0].isVisible = false
        XCTAssertNil(TransformSession(model: model, history: history), "hidden layer")
    }

    func testFreeTransformCornerHandleScales() {
        let tool = FreeTransformTool(session: TransformSession(model: model, history: history)!)
        var ctx = context
        ctx.zoom = 1
        // Drag the bottom-right corner (20, 20) to (30, 30): the box grows to 20×20.
        _ = tool.begin(ToolEvent(location: CGPoint(x: 20, y: 20), pressure: 1, modifiers: []), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 30, y: 30), pressure: 1, modifiers: []), context: ctx)
        _ = tool.end(ToolEvent(location: CGPoint(x: 30, y: 30), pressure: 1, modifiers: []), context: ctx)
        grouped { tool.session.commit(actionName: "Free Transform") }
        XCTAssertEqual(bitmap.pixel(x: 12, y: 12), red.rgba8, "top-left corner stays put")
        XCTAssertEqual(bitmap.pixel(x: 28, y: 28), red.rgba8)
        XCTAssertEqual(bitmap.pixel(x: 32, y: 32), .clear)
    }

    func testFreeTransformRotateHalfTurn() {
        model.layers[0].bitmap.clear()
        model.layers[0].bitmap.fill(red, in: CGRect(x: 10, y: 10, width: 20, height: 4)) // a bar
        let tool = FreeTransformTool(session: TransformSession(model: model, history: history)!)
        // Grab outside the box (rotate) to the right of the center, drag to below it: +90°.
        _ = tool.begin(ToolEvent(location: CGPoint(x: 50, y: 12), pressure: 1, modifiers: []), context: context)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 20, y: 60), pressure: 1, modifiers: [.shift]), context: context)
        grouped { tool.session.commit(actionName: "Free Transform") }
        XCTAssertEqual(bitmap.pixel(x: 20, y: 4).a, 255, "the bar now stands vertically through the center")
        XCTAssertEqual(bitmap.pixel(x: 12, y: 12).a, 0)
    }

    func testQuadMatchingTheSourceLeavesPixelsInPlace() {
        let session = TransformSession(model: model, history: history)!
        session.apply(quad: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 10, y: 20)])
        XCTAssertEqual(bitmap.pixel(x: 10, y: 10).a, 255, "y isn't flipped by the Core Image round trip")
        XCTAssertEqual(bitmap.pixel(x: 19, y: 19).a, 255)
        XCTAssertEqual(bitmap.pixel(x: 15, y: 15).r, 255)
        XCTAssertEqual(bitmap.pixel(x: 21, y: 15).a, 0)
        XCTAssertEqual(bitmap.pixel(x: 15, y: 21).a, 0)
    }

    func testCommandDragDistortsOneCorner() {
        let tool = FreeTransformTool(session: TransformSession(model: model, history: history)!)
        var ctx = context
        ctx.zoom = 1
        // ⌘-drag the bottom-right corner (20, 20) out to (60, 50); the other three stay.
        _ = tool.begin(ToolEvent(location: CGPoint(x: 20, y: 20), pressure: 1, modifiers: [.command]), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 60, y: 50), pressure: 1, modifiers: [.command]), context: ctx)
        _ = tool.end(ToolEvent(location: CGPoint(x: 60, y: 50), pressure: 1, modifiers: [.command]), context: ctx)
        XCTAssertTrue(tool.isDistorted)
        XCTAssertEqual(tool.corners, [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 50), CGPoint(x: 10, y: 20)])
        grouped { tool.session.commit(actionName: "Free Transform") }

        XCTAssertEqual(bitmap.pixel(x: 11, y: 11).a, 255, "fixed corner keeps its pixels")
        XCTAssertEqual(bitmap.pixel(x: 50, y: 42).a, 255, "stretched toward the moved corner")
        XCTAssertEqual(bitmap.pixel(x: 50, y: 20).a, 0, "outside the new shape")
        XCTAssertEqual(bitmap.pixel(x: 15, y: 40).a, 0)

        undo.undo()
        XCTAssertEqual(bitmap.pixel(x: 50, y: 42).a, 0)
        XCTAssertEqual(bitmap.pixel(x: 15, y: 15), red.rgba8)
    }

    func testDistortedSelectionFollowsThePixels() {
        model.selection = Selection.shape(CGPath(rect: CGRect(x: 10, y: 10, width: 10, height: 10), transform: nil),
                                          width: 100, height: 100)
        let session = TransformSession(model: model, history: history)!
        grouped {
            session.apply(quad: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 40, y: 40), CGPoint(x: 10, y: 20)])
            session.commit(actionName: "Free Transform")
        }
        guard let selection = model.selection else { return XCTFail("selection lost") }
        XCTAssertEqual(selection.coverage(x: 35, y: 30), 255)
        XCTAssertEqual(selection.coverage(x: 12, y: 35), 0)
    }

    func testMoveStillWorksAfterDistorting() {
        let tool = FreeTransformTool(session: TransformSession(model: model, history: history)!)
        var ctx = context
        ctx.zoom = 4 // handles 2 px wide, so a drag inside this small shape isn't a handle
        _ = tool.begin(ToolEvent(location: CGPoint(x: 20, y: 20), pressure: 1, modifiers: [.command]), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 30, y: 30), pressure: 1, modifiers: [.command]), context: ctx)
        _ = tool.end(ToolEvent(location: CGPoint(x: 30, y: 30), pressure: 1, modifiers: []), context: ctx)
        // Drag from inside the (now bigger) shape: everything moves by (40, 0).
        _ = tool.begin(ToolEvent(location: CGPoint(x: 18, y: 18), pressure: 1, modifiers: []), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 58, y: 18), pressure: 1, modifiers: []), context: ctx)
        XCTAssertEqual(tool.corners[0], CGPoint(x: 50, y: 10))
        XCTAssertEqual(tool.corners[2], CGPoint(x: 70, y: 30))
    }

    func testHomographyMapsTheCorners() {
        let quad = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 50), CGPoint(x: 10, y: 20)]
        let m = Homography(unitSquareTo: quad)
        for (unit, expected) in zip([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], quad) {
            let p = m.map(unit)!
            XCTAssertEqual(p.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(p.y, expected.y, accuracy: 0.001)
        }
    }

    func testSnapperLinesUpEdgesAndCenters() {
        let snapper = Snapper(canvas: CGRect(x: 0, y: 0, width: 100, height: 100), zoom: 1)
        let near = snapper.offset(for: CGRect(x: 3, y: 95, width: 10, height: 2))
        XCTAssertEqual(near.delta, CGPoint(x: -3, y: 3), "left edge → 0, bottom edge → 100")
        XCTAssertEqual(near.guides, Snapper.Guides(x: 0, y: 100))
        let centered = snapper.offset(for: CGRect(x: 44, y: 30, width: 10, height: 10))
        XCTAssertEqual(centered.delta, CGPoint(x: 1, y: 0), "center 49 → 50; y is too far from anything")
        XCTAssertNil(centered.guides.y)
        XCTAssertEqual(Snapper(canvas: CGRect(x: 0, y: 0, width: 100, height: 100), zoom: 4).offset(for: CGRect(x: 3, y: 30, width: 10, height: 10)).delta,
                       .zero, "zoomed in, 3 px is beyond the 8-point snap distance")
    }

    func testMoveToolSnapsTheLayerIntoTheCorner() {
        let tool = MoveTool()
        var ctx = context
        ctx.zoom = 1
        // The square at (10,10) dragged by (-6, -7) lands 4,3 px from the corner: it snaps in.
        grouped {
            _ = tool.begin(ToolEvent(location: CGPoint(x: 15, y: 15), pressure: 1, modifiers: []), context: ctx)
            _ = tool.drag(ToolEvent(location: CGPoint(x: 9, y: 8), pressure: 1, modifiers: []), context: ctx)
            _ = tool.end(ToolEvent(location: CGPoint(x: 9, y: 8), pressure: 1, modifiers: []), context: ctx)
        }
        XCTAssertEqual(TransformSession.contentBounds(of: bitmap), CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testControlKeySkipsSnapping() {
        let tool = MoveTool()
        var ctx = context
        ctx.zoom = 1
        grouped {
            _ = tool.begin(ToolEvent(location: CGPoint(x: 15, y: 15), pressure: 1, modifiers: [.control]), context: ctx)
            _ = tool.drag(ToolEvent(location: CGPoint(x: 9, y: 8), pressure: 1, modifiers: [.control]), context: ctx)
            _ = tool.end(ToolEvent(location: CGPoint(x: 9, y: 8), pressure: 1, modifiers: [.control]), context: ctx)
        }
        XCTAssertEqual(TransformSession.contentBounds(of: bitmap), CGRect(x: 4, y: 3, width: 10, height: 10))
    }

    func testFreeTransformMoveAndCornerSnap() {
        let tool = FreeTransformTool(session: TransformSession(model: model, history: history)!)
        var ctx = context
        ctx.zoom = 4 // 2-px snap distance and handles, so the small square is easy to grab
        // Drag the box so its right edge lands 1 px from the canvas center line (50).
        _ = tool.begin(ToolEvent(location: CGPoint(x: 15, y: 15), pressure: 1, modifiers: []), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 44, y: 15), pressure: 1, modifiers: []), context: ctx)
        _ = tool.end(ToolEvent(location: CGPoint(x: 44, y: 15), pressure: 1, modifiers: []), context: ctx)
        XCTAssertEqual(tool.corners[1], CGPoint(x: 50, y: 10), "top-right corner on the center line")
        // Drag the bottom-right corner to 1 px short of the canvas's bottom-right corner.
        _ = tool.begin(ToolEvent(location: CGPoint(x: 50, y: 20), pressure: 1, modifiers: []), context: ctx)
        _ = tool.drag(ToolEvent(location: CGPoint(x: 99, y: 99), pressure: 1, modifiers: []), context: ctx)
        XCTAssertEqual(tool.corners[2], CGPoint(x: 100, y: 100))
    }
}
