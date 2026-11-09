import SwiftUI

/// SwiftUI bridge to the AppKit canvas.
struct CanvasView: NSViewRepresentable {
    let model: CanvasModel
    let editor: EditorState
    let history: HistoryManager
    let viewport: Viewport
    /// The document's undo manager (from the SwiftUI environment).
    let undoManager: UndoManager?

    func makeNSView(context: Context) -> CanvasNSView {
        history.undoManager = undoManager
        return CanvasNSView(model: model, editor: editor, history: history, viewport: viewport)
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        history.undoManager = undoManager
        view.model = model
        view.editor = editor
        view.history = history
        view.viewport = viewport
    }
}
