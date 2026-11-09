import AppKit

/// Drag to pan. Also used temporarily while Space is held, from any tool.
///
/// "Grab" semantics: the canvas point under the pointer at mouse-down stays under the
/// pointer, so the tool only needs canvas coordinates and asks the host to pan.
final class HandTool: Tool {
    var cursor: NSCursor { .openHand }
    private var grabbed: CGPoint?

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        grabbed = event.location
        NSCursor.closedHand.set()
        return .null
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        guard let grabbed else { return .null }
        context.host?.pan(byCanvasDelta: event.location - grabbed)
        return .null
    }

    func end(_ event: ToolEvent, context: ToolContext) -> CGRect {
        grabbed = nil
        return .null
    }
}
