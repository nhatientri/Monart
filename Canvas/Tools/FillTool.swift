import AppKit

/// Paint bucket: floods the clicked region of the active layer with the primary color.
final class FillTool: Tool {
    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let layer = context.model.activeLayer, layer.isVisible,
              layer.bitmap.bounds.contains(event.location) else { return .null }
        context.history.beginEdit(on: layer)
        let tolerance = Int((context.editor.fillTolerance * 255).rounded())
        let dirty = FloodFill.fill(layer.bitmap, at: event.location,
                                   color: context.editor.primaryColor, tolerance: tolerance,
                                   within: context.model.selection)
        context.history.commit(dirtyRect: dirty, actionName: "Fill")
        return dirty
    }
}
