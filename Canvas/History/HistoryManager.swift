import CoreGraphics
import Foundation

/// Records edits as undoable actions on the document's `UndoManager`.
///
/// Two kinds of edit:
/// - **Pixels.** Usage from a tool: `beginEdit(on:)` when a stroke starts, then
/// `commit(dirtyRect:actionName:)` with the union of everything it touched. Only that
/// rect is kept (before and after), so an undo step costs a few KB to a few MB, not a
/// whole layer.
/// - **Layer stack** (add, delete, duplicate, reorder): `performLayerChange` snapshots
///   the layer array before and after. `Layer` is a reference type, so a deleted layer
///   lives on inside the undo action, pixels and all, and undo just puts it back.
final class HistoryManager {
    static let maxSteps = 50

    var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            undoManager?.levelsOfUndo = Self.maxSteps
        }
    }

    /// Called after undo/redo changes pixels, so the canvas can redraw that rect.
    var onRestore: ((Layer, CGRect) -> Void)?

    private var editingLayer: Layer?
    /// Full copy of the layer taken at `beginEdit`, reused between strokes.
    private var before: Bitmap?

    var isEditing: Bool { editingLayer != nil }

    func beginEdit(on layer: Layer) {
        let bitmap = layer.bitmap
        if before?.width != bitmap.width || before?.height != bitmap.height {
            before = Bitmap(width: bitmap.width, height: bitmap.height)
        }
        before?.copyContents(of: bitmap)
        editingLayer = layer
    }

    func commit(dirtyRect: CGRect, actionName: String) {
        guard let layer = editingLayer, let before else { return }
        editingLayer = nil
        layer.noteContentChanged()
        let rect = dirtyRect.pixelAligned(clampedTo: layer.bitmap.bounds)
        guard !rect.isNull, undoManager != nil else { return }
        let old = BitmapSnapshot(of: before, rect: rect)
        let new = BitmapSnapshot(of: layer.bitmap, rect: rect)
        registerRestore(of: old, inverse: new, on: layer, actionName: actionName)
    }

    func cancelEdit() {
        editingLayer = nil
    }

    /// Forgets every recorded step, e.g. when the document's canvas is replaced.
    func reset() {
        editingLayer = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Registers "put `snapshot` back"; performing it registers the inverse, which is how redo works.
    private func registerRestore(of snapshot: BitmapSnapshot, inverse: BitmapSnapshot,
                                 on layer: Layer, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { history in
            snapshot.restore(into: layer.bitmap)
            layer.noteContentChanged()
            history.onRestore?(layer, snapshot.rect)
            history.registerRestore(of: inverse, inverse: snapshot, on: layer, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Layer stack

    /// Runs `change` (which mutates `model.layers` / `activeLayerID`) as one undo step.
    /// Does nothing to the history if the layer order didn't actually change.
    func performLayerChange(in model: CanvasModel, actionName: String, _ change: () -> Void) {
        let before = LayerStackState(model)
        change()
        let after = LayerStackState(model)
        guard before != after else { return }
        registerLayerStack(before, inverse: after, in: model, actionName: actionName)
    }

    private func registerLayerStack(_ state: LayerStackState, inverse: LayerStackState,
                                    in model: CanvasModel, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { history in
            state.apply(to: model)
            history.registerLayerStack(inverse, inverse: state, in: model, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }
}

/// Which layers a canvas has, in which order, and which one is active.
private struct LayerStackState: Equatable {
    let layers: [Layer]
    let activeLayerID: Layer.ID?

    init(_ model: CanvasModel) {
        layers = model.layers
        activeLayerID = model.activeLayerID
    }

    func apply(to model: CanvasModel) {
        model.layers = layers
        model.activeLayerID = activeLayerID
    }

    /// Equal when the layer order is the same; a selection change alone isn't an undo step.
    static func == (a: Self, b: Self) -> Bool {
        a.layers.map(\.id) == b.layers.map(\.id)
    }
}
