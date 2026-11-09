import AppKit

/// Shows the canvas's flattened pixels (`CanvasNSView.composite`) as a Core Animation layer.
///
/// The GPU scales and positions the image, so panning and zooming only move this view's
/// frame: no pixels are recomposited or resampled on the CPU. When pixels change, the canvas
/// view marks this view as needing display and `updateLayer()` hands the layer a fresh image.
final class CanvasImageView: NSView {
    weak var canvas: CanvasNSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        guard let layer, let canvas else { return }
        layer.contents = canvas.flushComposite()
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = canvas.zoom >= 2 ? .nearest : .linear
    }

    /// Pointer events belong to the canvas view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Transient drawing above the pixels: selection outline, tool previews, Free Transform
/// handles and snap guides. Cheap to redraw, so it is simply redrawn in the rects that change.
final class CanvasOverlayView: NSView {
    weak var canvas: CanvasNSView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        canvas?.drawOverlay(dirtyRect)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
