import XCTest
@testable import Monart

final class DocumentFormatTests: XCTestCase {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    /// Two layers with distinct names, visibility, opacity and pixels; transparent background.
    private func makeModel() -> CanvasModel {
        let model = CanvasModel(width: 64, height: 48, background: nil)
        let bottom = model.layers[0]
        bottom.name = "Sketch"
        bottom.bitmap.fill(red, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let top = model.addLayer()
        top.name = "Ink"
        top.isVisible = false
        top.opacity = 0.4
        top.bitmap.fill(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5), in: CGRect(x: 20, y: 20, width: 8, height: 8))
        model.activeLayerID = bottom.id
        return model
    }

    private func roundTrip(_ model: CanvasModel) throws -> CanvasModel {
        let wrapper = try DocumentFormat.fileWrapper(for: DocumentFormat.Snapshot(model))
        return try DocumentFormat.read(wrapper)
    }

    func testRoundTripPreservesLayersAndProperties() throws {
        let original = makeModel()
        let loaded = try roundTrip(original)

        XCTAssertEqual(loaded.width, 64)
        XCTAssertEqual(loaded.height, 48)
        XCTAssertNil(loaded.background)
        XCTAssertEqual(loaded.layers.map(\.id), original.layers.map(\.id), "same layers, same order")
        XCTAssertEqual(loaded.layers.map(\.name), ["Sketch", "Ink"])
        XCTAssertEqual(loaded.layers.map(\.isVisible), [true, false])
        XCTAssertEqual(loaded.layers[1].opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(loaded.activeLayerID, original.layers[0].id)
    }

    func testRoundTripPreservesPixels() throws {
        let loaded = try roundTrip(makeModel())
        XCTAssertEqual(loaded.layers[0].bitmap.pixel(x: 5, y: 5), red.rgba8, "opaque pixels exact, top-left stays top-left")
        XCTAssertEqual(loaded.layers[0].bitmap.pixel(x: 40, y: 40), .clear)

        // Semi-transparent pixels go through PNG's un-premultiplied storage; allow rounding.
        let p = loaded.layers[1].bitmap.pixel(x: 22, y: 22)
        XCTAssertEqual(Int(p.b), 255, accuracy: 2)
        XCTAssertEqual(Int(p.a), 128, accuracy: 2)
    }

    func testBackgroundColorRoundTrips() throws {
        let model = CanvasModel(width: 8, height: 8,
                                background: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let loaded = try roundTrip(model)
        XCTAssertEqual(loaded.background?.rgba8, model.background?.rgba8)
    }

    func testPackageLayout() throws {
        let model = makeModel()
        let wrapper = try DocumentFormat.fileWrapper(for: DocumentFormat.Snapshot(model))
        let files = try XCTUnwrap(wrapper.fileWrappers)
        XCTAssertNotNil(files["manifest.json"])
        XCTAssertNotNil(files["thumbnail.png"])
        let layerFiles = try XCTUnwrap(files["layers"]?.fileWrappers)
        XCTAssertEqual(Set(layerFiles.keys), Set(model.layers.map { "\($0.id.uuidString).png" }))

        let manifest = try JSONDecoder().decode(DocumentFormat.Manifest.self,
                                                from: XCTUnwrap(files["manifest.json"]?.regularFileContents))
        XCTAssertEqual(manifest.version, DocumentFormat.currentVersion)
        XCTAssertEqual(manifest.layers.map(\.name), ["Sketch", "Ink"])
    }

    func testWritesToDiskAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("canvas")
        defer { try? FileManager.default.removeItem(at: url) }
        let wrapper = try DocumentFormat.fileWrapper(for: DocumentFormat.Snapshot(makeModel()))
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)

        let loaded = try DocumentFormat.read(FileWrapper(url: url))
        XCTAssertEqual(loaded.layers.map(\.name), ["Sketch", "Ink"])
    }

    // MARK: Damaged or unsupported files

    private func wrapper(editingManifest edit: (inout DocumentFormat.Manifest) -> Void) throws -> FileWrapper {
        let original = try DocumentFormat.fileWrapper(for: DocumentFormat.Snapshot(makeModel()))
        var files = try XCTUnwrap(original.fileWrappers)
        var manifest = try JSONDecoder().decode(DocumentFormat.Manifest.self,
                                                from: XCTUnwrap(files["manifest.json"]?.regularFileContents))
        edit(&manifest)
        files["manifest.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
        return FileWrapper(directoryWithFileWrappers: files)
    }

    func testRejectsNewerVersion() throws {
        let newer = try wrapper { $0.version = DocumentFormat.currentVersion + 1 }
        XCTAssertThrowsError(try DocumentFormat.read(newer)) { error in
            guard case DocumentFormat.FormatError.newerVersion = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsMissingLayerFile() throws {
        let broken = try wrapper { $0.layers[0].file = "layers/nope.png" }
        XCTAssertThrowsError(try DocumentFormat.read(broken))
    }

    func testRejectsPathsOutsideThePackage() throws {
        let escaping = try wrapper { $0.layers[0].file = "../../etc/passwd" }
        XCTAssertThrowsError(try DocumentFormat.read(escaping))
    }

    func testRejectsLayerOfWrongSize() throws {
        let mismatched = try wrapper { $0.width = 10 }
        XCTAssertThrowsError(try DocumentFormat.read(mismatched))
    }

    func testRejectsNonPackage() {
        XCTAssertThrowsError(try DocumentFormat.read(FileWrapper(regularFileWithContents: Data("hi".utf8))))
    }

    func testRepairsDuplicateLayerIDs() throws {
        let duplicated = try wrapper { $0.layers[1].id = $0.layers[0].id }
        let loaded = try DocumentFormat.read(duplicated)
        XCTAssertEqual(Set(loaded.layers.map(\.id)).count, 2)
    }

    // MARK: Version 2: blend modes

    func testBlendModeRoundTrips() throws {
        let model = makeModel()
        model.layers[1].blendMode = .multiply
        let loaded = try roundTrip(model)
        XCTAssertEqual(loaded.layers.map(\.blendMode), [.normal, .multiply])
    }

    func testVersion1FilesStillOpenWithNormalBlending() throws {
        let old = try wrapper { manifest in
            manifest.version = 1
            for i in manifest.layers.indices { manifest.layers[i].blendMode = nil }
        }
        let loaded = try DocumentFormat.read(old)
        XCTAssertEqual(loaded.layers.map(\.blendMode), [.normal, .normal])
    }

    func testUnknownBlendModeFallsBackToNormal() throws {
        let odd = try wrapper { $0.layers[0].blendMode = "glitter" }
        XCTAssertEqual(try DocumentFormat.read(odd).layers[0].blendMode, .normal)
    }
}
