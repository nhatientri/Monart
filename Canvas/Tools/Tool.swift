import AppKit

/// One pointer sample, already converted to canvas pixel coordinates.
struct ToolEvent {
    var location: CGPoint
    var pressure: CGFloat
    var modifiers: NSEvent.ModifierFlags
}

/// Services the canvas view offers tools that need more than pixels (e.g. a text field).
protocol ToolHost: AnyObject {
    /// Shows an editable text field whose top-left is at `canvasPoint`.
    func beginTextEntry(at canvasPoint: CGPoint)
    /// Scrolls the view so the canvas moves by `delta` canvas pixels.
    func pan(byCanvasDelta delta: CGPoint)
}

/// What a tool may read and modify.
struct ToolContext {
    let model: CanvasModel
    let editor: EditorState
    let history: HistoryManager
    weak var host: ToolHost?
    /// View points per canvas pixel — only for sizing on-screen handles, never for pixels.
    var zoom: CGFloat = 1
}

/// Tools work purely in canvas pixel coordinates. Each event method returns the
/// canvas-space rect it changed (`.null` if nothing) so the view can redraw just that.
/// A tool showing a live preview returns the preview's old and new area.
protocol Tool: AnyObject {
    var cursor: NSCursor { get }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect
    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect
    func end(_ event: ToolEvent, context: ToolContext) -> CGRect

    /// Draws transient overlay (e.g. a shape preview). `ctx` is in canvas coordinates.
    func drawPreview(in ctx: CGContext, context: ToolContext)
}

extension Tool {
    var cursor: NSCursor { .crosshair }
    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect { .null }
    func end(_ event: ToolEvent, context: ToolContext) -> CGRect { .null }
    func drawPreview(in ctx: CGContext, context: ToolContext) {}
}

extension ToolKind {
    func makeTool() -> Tool {
        switch self {
        case .brush: BrushTool()
        case .eraser: EraserTool()
        case .line: ShapeTool(shape: .line)
        case .rectangle: ShapeTool(shape: .rectangle)
        case .ellipse: ShapeTool(shape: .ellipse)
        case .fill: FillTool()
        case .text: TextTool()
        case .eyedropper: EyedropperTool()
        case .hand: HandTool()
        case .select: SelectTool()
        case .magicWand: MagicWandTool()
        case .move: MoveTool()
        }
    }
}
