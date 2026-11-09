import CoreGraphics
import Foundation

/// A canvas's size and background, as chosen in the Canvas Size sheet.
///
/// New documents open straight onto `CanvasSetup.default` (1920 × 1080 white, or what the
/// user saved with "Use for new canvases") instead of asking first.
struct CanvasSetup: Codable, Equatable {
    enum Background: String, Codable, CaseIterable, Identifiable {
        case white, transparent, color

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var width = 1920
    var height = 1080
    var background: Background = .white
    /// sRGB components used when `background == .color`.
    var color: [Double] = [0.95, 0.92, 0.85]

    init() {}

    init(width: Int, height: Int, background: Background = .white) {
        self.width = width
        self.height = height
        self.background = background
    }

    /// The current settings of an open canvas.
    init(_ model: CanvasModel) {
        width = model.width
        height = model.height
        if let bg = model.background {
            let rgb = bg.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil)?.components ?? []
            if rgb.count >= 3 {
                let components = rgb.prefix(3).map(Double.init)
                if components.allSatisfy({ $0 >= 0.999 }) {
                    background = .white
                } else {
                    background = .color
                    color = components
                }
            }
        } else {
            background = .transparent
        }
    }

    static let sizeRange = 1...Bitmap.maxDimension
    var isValid: Bool { Self.sizeRange.contains(width) && Self.sizeRange.contains(height) }

    var backgroundColor: CGColor? {
        switch background {
        case .white: .white
        case .transparent: nil
        case .color: CGColor(srgbRed: color[safe: 0], green: color[safe: 1], blue: color[safe: 2], alpha: 1)
        }
    }

    func makeModel() -> CanvasModel {
        CanvasModel(width: width, height: height, background: backgroundColor)
    }

    // MARK: Default for new documents

    static let defaultsKey = "NewCanvasSetup"

    static func savedDefault(in defaults: UserDefaults = .standard) -> CanvasSetup {
        guard let data = defaults.data(forKey: defaultsKey),
              let setup = try? JSONDecoder().decode(CanvasSetup.self, from: data), setup.isValid else {
            return CanvasSetup()
        }
        return setup
    }

    func saveAsDefault(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

private extension Array where Element == Double {
    subscript(safe i: Int) -> CGFloat { i < count ? CGFloat(self[i]) : 1 }
}
