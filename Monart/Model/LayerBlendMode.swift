import CoreGraphics

/// How a layer's pixels combine with everything below it.
enum LayerBlendMode: String, CaseIterable, Identifiable {
    case normal
    case darken, multiply, colorBurn
    case lighten, screen, colorDodge
    case overlay, softLight, hardLight
    case difference, exclusion
    case hue, saturation, color, luminosity

    var id: String { rawValue }

    /// Menu order, grouped the usual way (darkening, lightening, contrast, comparative, color).
    static let menuGroups: [[LayerBlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn],
        [.lighten, .screen, .colorDodge],
        [.overlay, .softLight, .hardLight],
        [.difference, .exclusion],
        [.hue, .saturation, .color, .luminosity],
    ]

    var title: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .darken: .darken
        case .multiply: .multiply
        case .colorBurn: .colorBurn
        case .lighten: .lighten
        case .screen: .screen
        case .colorDodge: .colorDodge
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}
