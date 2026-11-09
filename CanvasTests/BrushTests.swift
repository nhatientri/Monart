import XCTest
@testable import Canvas

final class BrushTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    /// One dab at (50, 50) on a 100×100 bitmap.
    private func dab(_ configure: (inout BrushSettings) -> Void, tip: BrushTipImage? = nil) -> Bitmap {
        let bitmap = Bitmap(width: 100, height: 100)
        var s = BrushSettings()
        s.size = 40
        configure(&s)
        _ = StrokeRenderer(bitmap: bitmap, color: red, settings: s, tipImage: tip).begin(at: CGPoint(x: 50, y: 50))
        return bitmap
    }

    func testSquareTipFillsCornersRoundDoesNot() {
        // (66, 66) is inside the 40 px square but outside the 40 px circle.
        XCTAssertEqual(dab { $0.tip = .square }.pixel(x: 66, y: 66).a, 255)
        XCTAssertEqual(dab { $0.tip = .round }.pixel(x: 66, y: 66).a, 0)
    }

    func testRoundnessMakesAFlatNibAndAngleTurnsIt() {
        let flat = dab { $0.roundness = 0.2 }              // 40 wide, 8 tall
        XCTAssertEqual(flat.pixel(x: 66, y: 50).a, 255)
        XCTAssertEqual(flat.pixel(x: 50, y: 58).a, 0)
        let turned = dab { $0.roundness = 0.2; $0.angle = 90 } // now 8 wide, 40 tall
        XCTAssertEqual(turned.pixel(x: 50, y: 66).a, 255)
        XCTAssertEqual(turned.pixel(x: 58, y: 50).a, 0)
    }

    func testImageTipStampsThePicture() {
        // Tip: left half painted, right half empty.
        var coverage = [UInt8](repeating: 0, count: 16 * 16)
        for y in 0..<16 { for x in 0..<8 { coverage[y * 16 + x] = 255 } }
        let tip = BrushTipImage(width: 16, height: 16, coverage: coverage)
        let bitmap = dab({ $0.tip = .image; $0.tipImageID = UUID() }, tip: tip)
        XCTAssertEqual(bitmap.pixel(x: 40, y: 50).a, 255)
        XCTAssertEqual(bitmap.pixel(x: 62, y: 50).a, 0)
    }

    func testChalkIsTextured() {
        let bitmap = dab { $0.tip = .chalk }
        var values = Set<UInt8>()
        for x in 35..<65 { values.insert(bitmap.pixel(x: x, y: 50).a) }
        XCTAssertGreaterThan(values.count, 5, "grainy, not a solid disc")
        XCTAssertEqual(bitmap.pixel(x: 5, y: 5).a, 0)
    }

    func testSprayLeavesGaps() {
        let bitmap = Bitmap(width: 200, height: 100)
        var s = BrushSettings()
        s.size = 60; s.tip = .spray; s.spacing = 0.25
        let r = StrokeRenderer(bitmap: bitmap, color: red, settings: s)
        _ = r.begin(at: CGPoint(x: 30, y: 50))
        _ = r.add(CGPoint(x: 170, y: 50))
        _ = r.end()
        var painted = 0, empty = 0
        for x in 30..<170 { bitmap.pixel(x: x, y: 50).a > 0 ? (painted += 1) : (empty += 1) }
        XCTAssertGreaterThan(painted, 5)
        XCTAssertGreaterThan(empty, 20, "dots, not a solid line")
    }

    func testScatterMovesDabsOffTheLineAndIsRepeatable() {
        func stroke() -> Bitmap {
            let bitmap = Bitmap(width: 200, height: 100)
            var s = BrushSettings()
            s.size = 6; s.scatter = 4; s.spacing = 1
            let r = StrokeRenderer(bitmap: bitmap, color: red, settings: s)
            _ = r.begin(at: CGPoint(x: 20, y: 50))
            _ = r.add(CGPoint(x: 180, y: 50))
            _ = r.end()
            return bitmap
        }
        let a = stroke(), b = stroke()
        var offLine = 0
        for y in 0..<100 where abs(y - 50) > 6 { for x in 0..<200 where a.pixel(x: x, y: y).a > 0 { offLine += 1 } }
        XCTAssertGreaterThan(offLine, 0)
        XCTAssertEqual(a.pixelData(in: a.bounds), b.pixelData(in: b.bounds), "same stroke, same result")
    }

    // MARK: Presets

    private func tempLibrary() -> (BrushLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (BrushLibrary(directory: dir), dir)
    }

    func testBuiltInPresetsAreStableAndApplyKeepingSize() {
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(library.builtIns.map(\.name).first, "Hard Round")
        let editor = EditorState()
        editor.brush.size = 77
        let calligraphy = library.builtIns.first { $0.name == "Calligraphy" }!
        editor.apply(calligraphy)
        XCTAssertEqual(editor.brush.size, 77)
        XCTAssertEqual(editor.brush.roundness, 0.2)
        XCTAssertEqual(editor.brushPresetID, calligraphy.id)
    }

    func testCustomPresetsPersistIncludingImageTips() {
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = BrushSettings()
        s.scatter = 0.5
        let plain = library.addPreset(name: "Mine", settings: s)
        let tip = BrushTipImage(width: 4, height: 4, coverage: [0, 255, 0, 255, 255, 0, 255, 0, 0, 255, 0, 255, 255, 0, 255, 0])
        let image = library.addPreset(name: "Checker", settings: s, tip: tip)

        let reloaded = BrushLibrary(directory: dir)
        XCTAssertEqual(reloaded.custom.map(\.name), ["Mine", "Checker"])
        XCTAssertEqual(reloaded.preset(plain.id)?.settings.scatter, 0.5)
        let loadedSettings = reloaded.preset(image.id)!.settings
        XCTAssertEqual(loadedSettings.tip, .image)
        XCTAssertEqual(reloaded.tipImage(for: loadedSettings), tip, "tip pixels survive the round trip")

        reloaded.delete(plain.id)
        XCTAssertEqual(BrushLibrary(directory: dir).custom.map(\.name), ["Checker"])
    }

    func testDefineBrushFromSelection() {
        let document = CanvasDocument(model: CanvasModel(width: 60, height: 60, background: nil))
        document.model.layers[0].bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                                             in: CGRect(x: 10, y: 10, width: 10, height: 20))
        document.model.selection = Selection.shape(CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20), transform: nil),
                                                   width: 60, height: 60)
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorState()
        document.defineBrushFromSelection(editor: editor, library: library)

        XCTAssertEqual(library.custom.count, 1)
        XCTAssertEqual(editor.brush.tip, .image)
        let tip = library.tipImage(for: editor.brush)!
        XCTAssertEqual(tip.width, 20)
        XCTAssertEqual(tip.sample(u: -0.5, v: 0), 1, accuracy: 0.01, "black paint → full coverage")
        XCTAssertEqual(tip.sample(u: 0.6, v: 0), 0, accuracy: 0.01, "transparent → none")
    }
}
