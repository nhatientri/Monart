import AppKit
import SwiftUI

/// The bar across the top: settings for the current tool.
struct ToolOptionsBar: View {
    @Bindable var editor: EditorState
    let viewport: Viewport

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies

    var body: some View {
        HStack(spacing: 16) {
            if viewport.isTransforming {
                transformOptions
            } else {
                Label(editor.tool.title, systemImage: editor.tool.systemImage)
                    .font(.headline)
                    .frame(width: 120, alignment: .leading)
                Divider().frame(height: 18)
                options
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// While Free Transform is open (⌘T, or right after pasting / dropping an image).
    @ViewBuilder
    private var transformOptions: some View {
        Label("Transform", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.headline)
            .frame(width: 120, alignment: .leading)
        Divider().frame(height: 18)
        Button("Cancel") { viewport.cancelTransform() }
            .help("Put it back as it was (Esc)")
        Button("Apply") { viewport.applyTransform() }
            .buttonStyle(.borderedProminent)
            .help("Keep the change (Return, or double-click)")
        snapToggle
        shortcutHint("Drag corners to resize (⇧ keeps shape) · Edges stretch · ⌘-drag a corner to distort · Drag outside to rotate · ⌃ skips snapping")
    }

    @ViewBuilder
    private var options: some View {
        switch editor.tool {
        case .brush, .eraser:
            BrushPresetMenu(editor: editor)
            OptionSlider(title: "Size", value: $editor.brush.size, range: BrushSettings.sizeRange,
                         width: 110, format: { "\(Int($0.rounded())) px" })
            OptionSlider(title: "Opacity", value: $editor.brush.opacity, range: 0.01...1,
                         width: 90, format: { "\(Int(($0 * 100).rounded()))%" })
            OptionSlider(title: "Hardness", value: $editor.brush.hardness, range: 0...1,
                         width: 90, format: { "\(Int(($0 * 100).rounded()))%" })
            // Pen-pressure options (BrushSettings.pressureControls…) are not shown: this app is
            // used with a trackpad/mouse, which always paints at full pressure. A pen tablet
            // still gets pressure → size by default.

        case .line:
            OptionSlider(title: "Width", value: $editor.shapeLineWidth,
                         range: EditorState.lineWidthRange, format: { "\(Int($0.rounded())) px" })
            shortcutHint("⇧ for 45°")

        case .rectangle, .ellipse:
            Picker("Style", selection: $editor.shapeFilled) {
                Text("Stroke").tag(false)
                Text("Fill").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !editor.shapeFilled {
                OptionSlider(title: "Width", value: $editor.shapeLineWidth,
                             range: EditorState.lineWidthRange, format: { "\(Int($0.rounded())) px" })
            }
            shortcutHint(editor.tool == .rectangle ? "⇧ for square" : "⇧ for circle")

        case .fill:
            OptionSlider(title: "Tolerance", value: $editor.fillTolerance,
                         range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })

        case .text:
            Picker("Font", selection: $editor.fontFamily) {
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 200)
            OptionSlider(title: "Size", value: $editor.fontSize,
                         range: EditorState.fontSizeRange, format: { "\(Int($0.rounded())) px" })
            shortcutHint("Click to type · Return to place · Esc to cancel")

        case .select:
            Picker("Shape", selection: $editor.selectShape) {
                ForEach(EditorState.SelectShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            shortcutHint("⇧ add · ⌥ subtract · ⇧⌥ intersect · Click to deselect · ⌘D deselect")

        case .magicWand:
            OptionSlider(title: "Tolerance", value: $editor.fillTolerance,
                         range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
            shortcutHint("⇧ add · ⌥ subtract · ⌘D deselect")

        case .move:
            Button {
                viewport.freeTransform()
            } label: {
                Label("Transform", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            .help("Resize, rotate or distort the selection or the whole layer (⌘T)")
            snapToggle
            shortcutHint("Drag to move the selection (or the whole layer) · ⇧ straight · ⌃ skips snapping · Arrow keys nudge (⇧ ×10)")

        case .hand:
            shortcutHint("Drag to pan · Hold Space to pan from any tool · Scroll to pan · Pinch or ⌘-scroll to zoom")

        case .eyedropper:
            shortcutHint("Click or drag on the canvas to pick a color. Hold ⌥ with other tools to pick temporarily.")
        }
    }

    private var snapToggle: some View {
        Toggle(isOn: $editor.snapping) {
            Label("Snap", systemImage: "square.and.line.vertical.and.square")
        }
        .toggleStyle(.button)
        .help("Snap to the canvas edges and center (⇧⌘;)")
    }

    private func shortcutHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct OptionSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    var width: CGFloat = 140
    let format: (Value) -> String

    var body: some View {
        HStack(spacing: 6) {
            // Labels never wrap; on a narrow window the slider gets shorter instead.
            Text(title)
                .lineLimit(1)
                .fixedSize()
            Slider(value: $value, in: range)
                .frame(minWidth: 50, maxWidth: width)
            Text(format(value))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)
        }
    }
}
