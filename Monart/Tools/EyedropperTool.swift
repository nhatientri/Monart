import AppKit

/// Sets the primary color from the composited canvas (all visible layers + background).
final class EyedropperTool: Tool {
    var cursor: NSCursor { Self.eyedropperCursor }

    func begin(_ event: ToolEvent, context: ToolContext) -> CGRect {
        sample(at: event.location, context: context)
        return .null
    }

    func drag(_ event: ToolEvent, context: ToolContext) -> CGRect {
        sample(at: event.location, context: context)
        return .null
    }

    private func sample(at point: CGPoint, context: ToolContext) {
        let c = Compositor.sampleColor(context.model,
                                       x: Int(point.x.rounded(.down)),
                                       y: Int(point.y.rounded(.down)))
        guard c.a > 0 else { return } // nothing there (transparent canvas)
        context.editor.primaryColor = CGColor(srgbRed: CGFloat(c.r) / 255,
                                              green: CGFloat(c.g) / 255,
                                              blue: CGFloat(c.b) / 255,
                                              alpha: 1)
    }

    /// The SF Symbol with a white halo so it's visible on dark paint. Hot spot is the tip (bottom-left).
    private static let eyedropperCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .crosshair }
        let size = NSSize(width: symbol.size.width + 2, height: symbol.size.height + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            func tinted(_ color: NSColor) -> NSImage {
                let copy = symbol.copy() as! NSImage
                copy.lockFocus()
                color.set()
                NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
                copy.unlockFocus()
                return copy
            }
            let halo = tinted(.white)
            for dx in [0, 2] as [CGFloat] { for dy in [0, 2] as [CGFloat] { halo.draw(at: NSPoint(x: dx, y: dy), from: .zero, operation: .sourceOver, fraction: 1) } }
            tinted(.black).draw(at: NSPoint(x: 1, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 2, y: size.height - 2))
    }()
}
