import AppKit
import UniformTypeIdentifiers

/// Undoable whole-selection edits and the clipboard. Used by the Edit menu and by the
/// canvas's Delete key.
enum PixelEdits {
    /// Pasteboard type remembering where copied pixels came from, so pasting puts them back
    /// in the same spot.
    static let originType = NSPasteboard.PasteboardType("com.hunter.canvas.origin")

    /// Delete: makes the selected pixels of the active layer transparent.
    static func clearSelection(model: CanvasModel, history: HistoryManager) {
        guard let selection = model.selection, let layer = model.activeLayer else { return }
        edit(layer, history: history, rect: selection.bounds, name: "Clear") { ctx in
            selection.clip(ctx)
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(selection.bounds)
        }
    }

    /// Fills the selection (or the whole layer) with `color`.
    static func fill(model: CanvasModel, history: HistoryManager, color: CGColor) {
        guard let layer = model.activeLayer else { return }
        let selection = model.selection
        edit(layer, history: history, rect: selection?.bounds ?? model.bounds, name: "Fill") { ctx in
            selection?.clip(ctx)
            ctx.setFillColor(color)
            ctx.fill(selection?.bounds ?? model.bounds)
        }
    }

    private static func edit(_ layer: Layer, history: HistoryManager, rect: CGRect, name: String,
                             _ draw: (CGContext) -> Void) {
        history.beginEdit(on: layer)
        let ctx = layer.bitmap.context
        ctx.saveGState()
        draw(ctx)
        ctx.restoreGState()
        history.commit(dirtyRect: rect, actionName: name)
    }

    // MARK: - Clipboard

    /// The selected pixels of the active layer (or the whole layer), cropped to the selection,
    /// with partially selected pixels made partly transparent. Also returns their canvas origin.
    static func copiedImage(model: CanvasModel) -> (image: CGImage, origin: CGPoint)? {
        guard let layer = model.activeLayer, let full = layer.bitmap.makeImage() else { return nil }
        guard let selection = model.selection else { return (full, .zero) }
        let rect = selection.bounds
        let crop = Bitmap(width: Int(rect.width), height: Int(rect.height))
        let ctx = crop.context
        ctx.saveGState()
        ctx.translateBy(x: -rect.minX, y: -rect.minY) // canvas coordinates
        selection.clip(ctx)
        ctx.drawUpright(full, in: model.bounds)
        ctx.restoreGState()
        guard let image = crop.makeImage() else { return nil }
        return (image, rect.origin)
    }

    @discardableResult
    static func copy(model: CanvasModel, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let (image, origin) = copiedImage(model: model),
              let png = try? DocumentFormat.pngData(image) else { return false }
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff, originType], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(cgImage: image, size: .zero).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        pasteboard.setString("\(Int(origin.x)),\(Int(origin.y))", forType: originType)
        return true
    }

    static func cut(model: CanvasModel, history: HistoryManager, to pasteboard: NSPasteboard = .general) {
        guard model.selection != nil, copy(model: model, to: pasteboard) else { return }
        clearSelection(model: model, history: history)
        history.undoManager?.setActionName("Cut")
    }

    /// The image on the pasteboard and, if it was copied from Canvas, where it came from.
    static func pastedImage(from pasteboard: NSPasteboard) -> (image: CGImage, origin: CGPoint?, name: String?)? {
        guard let (image, name) = ImageImporter.image(from: pasteboard) else { return nil }
        var origin: CGPoint?
        if let text = pasteboard.string(forType: originType) {
            let parts = text.split(separator: ",").compactMap { Int($0) }
            if parts.count == 2 { origin = CGPoint(x: parts[0], y: parts[1]) }
        }
        return (image, origin, name)
    }

    /// Paste: the pasteboard image as a new layer above the active one — back at its original
    /// position if it was copied from Canvas, otherwise centered (and shrunk to fit if it's
    /// bigger than the canvas).
    @discardableResult
    static func paste(into model: CanvasModel, history: HistoryManager,
                      from pasteboard: NSPasteboard = .general) -> Bool {
        guard let (image, origin, name) = pastedImage(from: pasteboard) else {
            NSSound.beep()
            return false
        }
        if let origin {
            addImageLayer(image, in: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)),
                          name: name ?? "Pasted", model: model, history: history, actionName: "Paste")
        } else {
            addImageLayer(image, centeredAt: nil, name: name ?? "Pasted", model: model, history: history,
                          actionName: "Paste")
        }
        return true
    }

    /// Adds `image` as a new layer above the active one, centered on `center` (canvas
    /// coordinates; default: the canvas center). Images bigger than the canvas are scaled
    /// down to fit — use Free Transform to resize further.
    static func addImageLayer(_ image: CGImage, centeredAt center: CGPoint?, name: String,
                              model: CanvasModel, history: HistoryManager, actionName: String) {
        var size = CGSize(width: image.width, height: image.height)
        let fit = min(1, CGFloat(model.width) / size.width, CGFloat(model.height) / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let c = center ?? CGPoint(x: CGFloat(model.width) / 2, y: CGFloat(model.height) / 2)
        let rect = CGRect(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        addImageLayer(image, in: rect, name: name, model: model, history: history, actionName: actionName)
    }

    private static func addImageLayer(_ image: CGImage, in rect: CGRect, name: String,
                                      model: CanvasModel, history: HistoryManager, actionName: String) {
        history.performLayerChange(in: model, actionName: actionName) {
            let layer = model.addLayer()
            layer.name = name
            let ctx = layer.bitmap.context
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.drawUpright(image, in: rect)
            ctx.restoreGState()
            layer.noteContentChanged()
        }
        model.selection = nil
    }
}
