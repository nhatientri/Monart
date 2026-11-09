/// Every tool the editor can have selected.
enum ToolKind: String, CaseIterable, Identifiable {
    case brush, eraser
    case line, rectangle, ellipse
    case fill, text, eyedropper
    case hand
    case select, magicWand, move

    var id: String { rawValue }

    /// How the tool palette groups tools (a divider between groups).
    static let paletteGroups: [[ToolKind]] = [
        [.brush, .eraser],
        [.line, .rectangle, .ellipse],
        [.fill, .text, .eyedropper],
        [.select, .magicWand, .move],
        [.hand],
    ]

    var title: String {
        switch self {
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .fill: "Fill"
        case .text: "Text"
        case .eyedropper: "Eyedropper"
        case .hand: "Hand"
        case .select: "Select"
        case .magicWand: "Magic Wand"
        case .move: "Move"
        }
    }

    var systemImage: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .fill: "drop.fill"
        case .text: "textformat"
        case .eyedropper: "eyedropper"
        case .hand: "hand.raised"
        case .select: "rectangle.dashed"
        case .magicWand: "wand.and.stars"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    /// Single-key shortcut (no modifiers), handled by `CanvasNSView`.
    var shortcut: String {
        switch self {
        case .brush: "b"
        case .eraser: "e"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .fill: "g"
        case .text: "t"
        case .eyedropper: "i"
        case .hand: "h"
        case .select: "m"
        case .magicWand: "w"
        case .move: "v"
        }
    }

    var isShape: Bool {
        self == .line || self == .rectangle || self == .ellipse
    }

    /// Holding ⌥ while pressing the mouse samples a color instead of using the tool.
    var allowsTemporaryEyedropper: Bool {
        // Selection tools use ⌥ to subtract from the selection instead.
        switch self {
        case .text, .eyedropper, .hand, .select, .magicWand, .move: false
        default: true
        }
    }
}
