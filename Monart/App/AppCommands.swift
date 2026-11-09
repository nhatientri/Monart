import SwiftUI

/// The focused window's document, published by `ContentView` so menu commands can reach it.
struct CanvasDocumentFocusedKey: FocusedValueKey {
    typealias Value = CanvasDocument
}

/// The focused window's editor settings (current colors), for menu commands.
struct EditorStateFocusedKey: FocusedValueKey {
    typealias Value = EditorState
}

/// The focused window's zoom state, for the View menu.
struct ViewportFocusedKey: FocusedValueKey {
    typealias Value = Viewport
}

extension FocusedValues {
    var canvasDocument: CanvasDocument? {
        get { self[CanvasDocumentFocusedKey.self] }
        set { self[CanvasDocumentFocusedKey.self] = newValue }
    }

    var viewport: Viewport? {
        get { self[ViewportFocusedKey.self] }
        set { self[ViewportFocusedKey.self] = newValue }
    }

    var editorState: EditorState? {
        get { self[EditorStateFocusedKey.self] }
        set { self[EditorStateFocusedKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.canvasDocument) private var document
    @FocusedValue(\.viewport) private var viewport
    @FocusedValue(\.editorState) private var editor

    /// Sends a standard text action to the field being typed in, or runs the canvas action.
    private func route(_ textAction: Selector, canvas: () -> Void) {
        if let field = NSApp.keyWindow?.firstResponder as? NSText {
            NSApp.sendAction(textAction, to: field, from: nil)
        } else {
            canvas()
        }
    }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export…") {
                if let document { ImageExporter.presentExportPanel(for: document.model) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(document == nil)
        }

        CommandGroup(before: .toolbar) {
            // ⌘= also zooms in (handled by the canvas view), for keyboards where + needs Shift.
            Button("Zoom In") { viewport?.zoomIn() }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(viewport == nil)
            Button("Zoom Out") { viewport?.zoomOut() }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(viewport == nil)
            Button("Zoom to Fit") { viewport?.zoomToFit() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(viewport == nil)
            Button("Actual Size") { viewport?.actualSize() }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(viewport == nil)
            Divider()
            Toggle("Snap", isOn: Binding(get: { editor?.snapping ?? true }, set: { editor?.snapping = $0 }))
                .keyboardShortcut(";", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Divider()
        }

        // Cut / Copy / Paste / Delete / Select All act on the canvas, except while typing
        // (layer rename, text tool), where the text field gets them as usual.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { route(#selector(NSText.cut(_:))) { document?.cut() } }
                .keyboardShortcut("x", modifiers: [.command])
            Button("Copy") { route(#selector(NSText.copy(_:))) { document?.copy() } }
                .keyboardShortcut("c", modifiers: [.command])
            // A pasted image opens in Free Transform, ready to resize, rotate or distort.
            Button("Paste") {
                route(#selector(NSText.paste(_:))) {
                    viewport?.applyTransform()
                    if document?.paste() == true { viewport?.freeTransform() }
                }
            }
                .keyboardShortcut("v", modifiers: [.command])
            Button("Delete") { route(#selector(NSText.delete(_:))) { document?.clearSelection() } }
            Divider()
            Button("Select All") { route(#selector(NSText.selectAll(_:))) { document?.selectAll() } }
                .keyboardShortcut("a", modifiers: [.command])
            Divider()
            Button("Define Brush from Selection") {
                if let document, let editor { document.defineBrushFromSelection(editor: editor) }
            }
            .disabled(document == nil)
            Button("Free Transform") { viewport?.freeTransform() }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(viewport == nil)
        }

        CommandMenu("Image") {
            Button("Canvas Size…") { editor?.showsCanvasSize = true }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(editor == nil)
        }

        CommandMenu("Select") {
            Button("All") { document?.selectAll() }
                .disabled(document == nil)
            Button("Deselect") { document?.deselect() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(document == nil)
            Button("Inverse") { document?.invertSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            Button("Fill with Primary Color") { if let document, let editor { document.fill(with: editor.primaryColor) } }
                .disabled(document == nil)
        }

        CommandMenu("Filter") {
            ForEach(FilterKind.allCases) { kind in
                Button(kind.title + (kind.hasSettings ? "…" : "")) {
                    if kind.hasSettings {
                        editor?.filterRequest = kind
                    } else {
                        document?.applyFilter(kind)
                    }
                }
                .disabled(document == nil)
                if kind == .grayscale || kind == .hueSaturation || kind == .sharpen { Divider() }
            }
        }

        CommandMenu("Layer") {
            Button("New Layer") { document?.addLayer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Duplicate Layer") { document?.duplicateActiveLayer() }
                .disabled(document == nil)
            Button("Delete Layer") { document?.deleteActiveLayer() }
                .disabled(document == nil)
            Divider()
            Button("Move Layer Up") { document?.moveActiveLayer(by: 1) }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(document == nil)
            Button("Move Layer Down") { document?.moveActiveLayer(by: -1) }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(document == nil)
        }
    }
}
