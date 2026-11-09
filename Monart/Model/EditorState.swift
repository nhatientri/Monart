import CoreGraphics
import Foundation
import Observation

/// Per-window editor settings: the current tool, colors and each tool's options.
@Observable
final class EditorState {
    var tool: ToolKind = .brush

    // Colors
    var primaryColor: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    var secondaryColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// Most recently used first.
    private(set) var recentColors: [CGColor] = []
    static let maxRecentColors = 16

    // Brush & eraser
    var brush = BrushSettings()
    /// The preset last chosen (its name is shown in the options bar).
    var brushPresetID: UUID? = BrushLibrary.shared.builtIns.first?.id

    /// Uses a preset's tip and dynamics, keeping the current size.
    func apply(_ preset: BrushLibrary.Preset) {
        var settings = preset.settings
        settings.size = brush.size
        brush = settings
        brushPresetID = preset.id
    }

    // Shapes
    static let lineWidthRange: ClosedRange<CGFloat> = 1...100
    var shapeLineWidth: CGFloat = 4
    /// Rectangles and ellipses: fill the interior instead of stroking the outline.
    var shapeFilled = false

    // Fill
    /// Per-channel color difference still treated as "the same", as a fraction of 255.
    var fillTolerance: Double = 0.12

    // Selection
    enum SelectShape: String, CaseIterable, Identifiable {
        case rectangle, ellipse, lasso
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    var selectShape: SelectShape = .rectangle

    // Text
    static let fontSizeRange: ClosedRange<CGFloat> = 6...400
    var fontFamily = "Helvetica"
    /// In canvas pixels.
    var fontSize: CGFloat = 48

    /// Moving and resizing snap to the canvas edges and center (View ▸ Snap; ⌃ while dragging skips it).
    var snapping = true

    /// A filter chosen from the Filter menu whose settings sheet should open.
    var filterRequest: FilterKind?
    /// Image ▸ Canvas Size… (or a click on the size in the status bar) opens its sheet.
    var showsCanvasSize = false

    /// X: swap primary and secondary colors.
    func swapColors() {
        (primaryColor, secondaryColor) = (secondaryColor, primaryColor)
    }

    /// Records the primary color as used (after a stroke, shape, fill or text).
    func noteColorUsed() {
        let key = primaryColor.rgba8
        recentColors.removeAll { $0.rgba8 == key }
        recentColors.insert(primaryColor, at: 0)
        if recentColors.count > Self.maxRecentColors {
            recentColors.removeLast(recentColors.count - Self.maxRecentColors)
        }
    }

    /// `[` / `]`: steps the current tool's size (brush size, line width or font size).
    func stepSize(_ direction: Int) {
        switch tool {
        case .brush, .eraser:
            brush.size = Self.step(brush.size, direction, in: BrushSettings.sizeRange)
        case .line, .rectangle, .ellipse:
            shapeLineWidth = Self.step(shapeLineWidth, direction, in: Self.lineWidthRange)
        case .text:
            fontSize = Self.step(fontSize, direction, in: Self.fontSizeRange)
        case .fill, .eyedropper, .hand, .select, .magicWand, .move:
            break
        }
    }

    /// Small steps for small sizes, bigger steps for big ones.
    static func step(_ value: CGFloat, _ direction: Int, in range: ClosedRange<CGFloat>) -> CGFloat {
        let v = value.rounded()
        let increment: CGFloat = direction > 0
            ? (v < 10 ? 1 : v < 50 ? 5 : 10)
            : (v <= 10 ? 1 : v <= 50 ? 5 : 10)
        return min(max(v + increment * CGFloat(direction.signum()), range.lowerBound), range.upperBound)
    }
}
