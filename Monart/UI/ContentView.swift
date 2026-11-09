import SwiftUI

/// Window layout: options bar on top; tool palette | canvas + status bar | sidebar below.
struct ContentView: View {
    @ObservedObject var document: CanvasDocument
    @State private var editor = EditorState()
    @State private var viewport = Viewport()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            ToolOptionsBar(editor: editor, viewport: viewport)
            Divider()
            HStack(spacing: 0) {
                ToolPalette(editor: editor)
                Divider()
                VStack(spacing: 0) {
                    CanvasView(model: document.model, editor: editor, history: document.history,
                               viewport: viewport, undoManager: undoManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    StatusBar(model: document.model, viewport: viewport) { editor.showsCanvasSize = true }
                }
                Divider()
                sidebar
                    .frame(width: 250)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .focusedSceneValue(\.canvasDocument, document)
        .focusedSceneValue(\.viewport, viewport)
        .focusedSceneValue(\.editorState, editor)
        .sheet(item: $editor.filterRequest) { kind in
            FilterSheet(kind: kind, document: document) { editor.filterRequest = nil }
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $editor.showsCanvasSize) {
            CanvasSizeSheet(current: CanvasSetup(document.model)) { setup, mode in
                document.changeCanvas(to: setup, mode: mode)
                editor.showsCanvasSize = false
            } onCancel: {
                editor.showsCanvasSize = false
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ColorPanel(editor: editor)
            Divider()
            LayersPanel(document: document)
        }
        .padding()
    }
}
