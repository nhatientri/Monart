import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Native layered document (a package). Declared as an exported type in Info.plist.
    static let canvasDocument = UTType(exportedAs: "com.hunter.canvas")
}

/// The document object SwiftUI's `DocumentGroup` manages. Owns the `CanvasModel`
/// and its edit history.
///
/// Reads and writes the native `.canvas` package (`DocumentFormat`). PNG/JPEG files open
/// as a new single-layer canvas (`ImageImporter`) and are saved as `.canvas`.
///
/// `model` is tracked with `@Observable` (like the other models), so views update when
/// Canvas Size swaps in a resized canvas. Edits mark the document dirty through the undo
/// manager.
@Observable
final class CanvasDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.canvasDocument, .png, .jpeg] }
    static var writableContentTypes: [UTType] { [.canvasDocument] }

    private(set) var model: CanvasModel
    @ObservationIgnored let history = HistoryManager()

    /// A brand-new document opens straight onto the default canvas; Image ▸ Canvas Size…
    /// changes it afterwards.
    init(model: CanvasModel = CanvasSetup.savedDefault().makeModel()) {
        self.model = model
    }

    init(configuration: ReadConfiguration) throws {
        if configuration.contentType.conforms(to: .canvasDocument) {
            model = try DocumentFormat.read(configuration.file)
        } else if configuration.contentType.conforms(to: .image) {
            guard let data = configuration.file.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            model = try ImageImporter.makeModel(from: data)
        } else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func snapshot(contentType: UTType) throws -> DocumentFormat.Snapshot {
        try DocumentFormat.Snapshot(model)
    }

    func fileWrapper(snapshot: DocumentFormat.Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try DocumentFormat.fileWrapper(for: snapshot)
    }

    /// Applies the Canvas Size sheet: a new size (resizing or cropping/extending the layers)
    /// and/or a new background, as one undo step.
    func changeCanvas(to setup: CanvasSetup, mode: CanvasModel.ResizeMode) {
        guard setup.isValid else { return }
        history.cancelEdit()
        if setup.width == model.width && setup.height == model.height {
            setBackground(setup.backgroundColor)
        } else {
            let resized = model.resized(width: setup.width, height: setup.height, mode: mode,
                                        background: setup.backgroundColor)
            swapModel(to: resized, actionName: "Canvas Size")
        }
    }

    private func setBackground(_ color: CGColor?) {
        let old = model.background
        guard old != color else { return }
        let target = model
        target.background = color
        history.undoManager?.registerUndo(withTarget: self) { document in
            guard document.model === target else { return }
            document.setBackground(old)
        }
        history.undoManager?.setActionName("Change Background")
    }

    /// Earlier undo steps keep pointing at the old canvas's layers, which is fine: undo runs
    /// newest first, so they only run after this swap has been undone and the old canvas is back.
    private func swapModel(to new: CanvasModel, actionName: String) {
        let old = model
        model = new
        history.undoManager?.registerUndo(withTarget: self) { document in
            document.swapModel(to: old, actionName: actionName)
        }
        history.undoManager?.setActionName(actionName)
    }
}

// MARK: - Undoable layer actions (used by LayersPanel and the Layer menu)

extension CanvasDocument {
    func addLayer() {
        history.performLayerChange(in: model, actionName: "Add Layer") { model.addLayer() }
    }

    func duplicateActiveLayer() {
        guard let id = model.activeLayerID else { return }
        history.performLayerChange(in: model, actionName: "Duplicate Layer") { model.duplicateLayer(id) }
    }

    func deleteActiveLayer() {
        guard let id = model.activeLayerID, model.canRemoveLayer else { return }
        history.performLayerChange(in: model, actionName: "Delete Layer") { model.removeLayer(id) }
    }

    /// `delta` > 0 moves toward the top of the stack.
    func moveActiveLayer(by delta: Int) {
        guard let id = model.activeLayerID else { return }
        history.performLayerChange(in: model, actionName: "Move Layer") { model.moveLayer(id, by: delta) }
    }

    func moveLayers(fromDisplayOffsets source: IndexSet, toDisplayOffset destination: Int) {
        history.performLayerChange(in: model, actionName: "Move Layer") {
            model.moveLayers(fromDisplayOffsets: source, toDisplayOffset: destination)
        }
    }

    // MARK: Selection & clipboard

    func selectAll() { model.selection = .all(width: model.width, height: model.height) }
    func deselect() { model.selection = nil }
    func invertSelection() { model.selection = model.selection?.inverted() }
    func clearSelection() { PixelEdits.clearSelection(model: model, history: history) }
    func fill(with color: CGColor) { PixelEdits.fill(model: model, history: history, color: color) }
    func copy() { PixelEdits.copy(model: model) }
    func cut() { PixelEdits.cut(model: model, history: history) }
    @discardableResult
    func paste() -> Bool { PixelEdits.paste(into: model, history: history) }

    /// Makes an image brush tip from the selected pixels and switches the brush to it.
    func defineBrushFromSelection(editor: EditorState, library: BrushLibrary = .shared) {
        guard model.selection != nil, let (image, _) = PixelEdits.copiedImage(model: model),
              let tip = BrushTipImage(image: image) else {
            NSSound.beep()
            return
        }
        var settings = editor.brush
        settings.tip = .image
        settings.roundness = 1
        settings.spacing = 0.25
        let preset = library.addPreset(name: library.nextCustomName(), settings: settings, tip: tip)
        editor.apply(preset)
        if editor.tool != .brush && editor.tool != .eraser { editor.tool = .brush }
    }

    /// Filters without settings (Invert, Grayscale) apply in one step.
    func applyFilter(_ kind: FilterKind) {
        guard let session = FilterSession(kind: kind, model: model, history: history) else {
            NSSound.beep()
            return
        }
        session.commit(FilterParameters())
    }

    var canMoveActiveLayerUp: Bool {
        guard let id = model.activeLayerID, let i = model.index(of: id) else { return false }
        return i < model.layers.count - 1
    }

    var canMoveActiveLayerDown: Bool {
        guard let id = model.activeLayerID, let i = model.index(of: id) else { return false }
        return i > 0
    }
}
