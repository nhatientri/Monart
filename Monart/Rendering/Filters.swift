import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Filter menu's effects, implemented with Core Image.
enum FilterKind: String, CaseIterable, Identifiable {
    case invert, grayscale, brightnessContrast, hueSaturation, gaussianBlur, sharpen, pixelate, posterize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .invert: "Invert"
        case .grayscale: "Grayscale"
        case .brightnessContrast: "Brightness/Contrast"
        case .hueSaturation: "Hue/Saturation"
        case .gaussianBlur: "Gaussian Blur"
        case .sharpen: "Sharpen"
        case .pixelate: "Pixelate"
        case .posterize: "Posterize"
        }
    }

    /// Filters with sliders open a settings sheet; the others apply right away.
    var hasSettings: Bool { self != .invert && self != .grayscale }
}

/// Every filter's settings, with neutral-ish defaults.
struct FilterParameters: Equatable {
    var brightness: Double = 0      // -0.5 … 0.5
    var contrast: Double = 1        // 0.25 … 2
    var hue: Double = 0             // degrees, -180 … 180
    var saturation: Double = 1      // 0 … 2
    var radius: Double = 4          // blur radius, px
    var sharpness: Double = 0.8     // 0 … 2
    var cellSize: Double = 12       // pixelate, px
    var levels: Double = 6          // posterize, 2 … 16
}

enum Filters {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.outputColorSpace: colorSpace])

    /// `image` with the filter applied, same size. Edges are handled by extending the border
    /// pixels, so blurs don't fade toward the canvas edges.
    static func apply(_ kind: FilterKind, _ p: FilterParameters, to image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let output: CIImage?
        switch kind {
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = input
            output = f.outputImage
        case .grayscale:
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 0
            output = f.outputImage
        case .brightnessContrast:
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.brightness = Float(p.brightness)
            f.contrast = Float(p.contrast)
            output = f.outputImage
        case .hueSaturation:
            let hue = CIFilter.hueAdjust()
            hue.inputImage = input
            hue.angle = Float(p.hue * .pi / 180)
            let sat = CIFilter.colorControls()
            sat.inputImage = hue.outputImage
            sat.saturation = Float(p.saturation)
            output = sat.outputImage
        case .gaussianBlur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = input.clampedToExtent()
            f.radius = Float(p.radius)
            output = f.outputImage?.cropped(to: extent)
        case .sharpen:
            let f = CIFilter.unsharpMask()
            f.inputImage = input.clampedToExtent()
            f.radius = 2.5
            f.intensity = Float(p.sharpness)
            output = f.outputImage?.cropped(to: extent)
        case .pixelate:
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(max(1, p.cellSize))
            f.center = CGPoint(x: extent.minX, y: extent.maxY) // cells line up with the top-left
            output = f.outputImage?.cropped(to: extent)
        case .posterize:
            let f = CIFilter.colorPosterize()
            f.inputImage = input
            f.levels = Float(p.levels.rounded())
            output = f.outputImage
        }
        guard let output else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }
}

/// Applies a filter to the active layer — only inside the selection if there is one — with a
/// live preview while its settings change, then one undo step (or a clean cancel).
final class FilterSession {
    let kind: FilterKind
    private let layer: Layer
    private let model: CanvasModel
    private let history: HistoryManager
    private let original: CGImage
    private let selection: Selection?

    /// Nil when the active layer is hidden.
    init?(kind: FilterKind, model: CanvasModel, history: HistoryManager) {
        guard let layer = model.activeLayer, layer.isVisible, let original = layer.bitmap.makeImage() else { return nil }
        self.kind = kind
        self.layer = layer
        self.model = model
        self.history = history
        self.original = original
        self.selection = model.selection
        history.beginEdit(on: layer)
    }

    func preview(_ parameters: FilterParameters) {
        guard let filtered = Filters.apply(kind, parameters, to: original) else { return }
        let bitmap = layer.bitmap
        if let selection {
            bitmap.replace(with: original, in: model.bounds)
            bitmap.context.saveGState()
            selection.clip(bitmap.context)
            bitmap.context.setBlendMode(.copy)
            bitmap.context.drawUpright(filtered, in: model.bounds)
            bitmap.context.restoreGState()
        } else {
            bitmap.replace(with: filtered, in: model.bounds)
        }
        layer.noteContentChanged() // the canvas and the layer thumbnail redraw
    }

    func commit(_ parameters: FilterParameters) {
        preview(parameters)
        history.commit(dirtyRect: selection?.bounds ?? model.bounds, actionName: kind.title)
    }

    func cancel() {
        layer.bitmap.replace(with: original, in: model.bounds)
        history.cancelEdit()
        layer.noteContentChanged()
    }
}
