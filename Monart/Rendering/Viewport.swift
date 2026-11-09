import CoreGraphics
import Observation

/// Per-window view state shared between the canvas view, the status bar and the View menu:
/// the current zoom and the canvas pixel under the pointer, plus zoom commands.
///
/// The canvas view owns the actual transform and publishes into this; commands are
/// forwarded to it.
@Observable
final class Viewport {
    static let zoomRange: ClosedRange<CGFloat> = 0.02...64
    /// Steps for zoom in / out (⌘+ / ⌘−).
    static let zoomLevels: [CGFloat] = [0.02, 0.05, 0.1, 0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1,
                                        1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    /// View points per canvas pixel.
    var zoom: CGFloat = 1
    /// Canvas pixel under the pointer, or nil when it's off the canvas.
    var cursorLocation: CGPoint?
    /// Free Transform is open (the options bar shows Apply / Cancel).
    var isTransforming = false

    @ObservationIgnored weak var view: CanvasNSView?

    func zoomIn() { view?.stepZoom(1) }
    func zoomOut() { view?.stepZoom(-1) }
    func zoomToFit() { view?.zoomToFit() }
    func actualSize() { view?.setZoom(1) }
    func freeTransform() { view?.beginFreeTransform() }
    func applyTransform() { view?.applyFreeTransform() }
    func cancelTransform() { view?.cancelFreeTransform() }

    static func nextLevel(after zoom: CGFloat, direction: Int) -> CGFloat {
        direction > 0
            ? zoomLevels.first { $0 > zoom * 1.001 } ?? zoomRange.upperBound
            : zoomLevels.last { $0 < zoom * 0.999 } ?? zoomRange.lowerBound
    }
}
