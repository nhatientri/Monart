import CoreGraphics

/// A brush that removes paint instead of adding it.
///
/// Uses `.destinationOut` with an opaque color rather than `.clear`: the result is the
/// same at full strength, but `.destinationOut` respects the fill's alpha, so eraser
/// opacity can be added later without changing this.
final class EraserTool: BrushTool {
    private static let opaque = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    override var blendMode: CGBlendMode { .destinationOut }
    override var actionName: String { "Erase" }
    override func strokeColor(_ editor: EditorState) -> CGColor { Self.opaque }
}
