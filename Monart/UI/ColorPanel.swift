import SwiftUI

/// Primary / secondary colors (X swaps them) and recently used colors.
struct ColorPanel: View {
    @Bindable var editor: EditorState

    private let swatchColumns = Array(repeating: GridItem(.fixed(20), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.headline)

            HStack(alignment: .top, spacing: 14) {
                colorWell("Primary", selection: $editor.primaryColor)
                colorWell("Secondary", selection: $editor.secondaryColor)
                Button {
                    editor.swapColors()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap Colors (X)")
                .padding(.top, 6)
            }

            if !editor.recentColors.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 6) {
                    ForEach(Array(editor.recentColors.enumerated()), id: \.offset) { _, color in
                        Button {
                            editor.primaryColor = color
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(cgColor: color))
                                .frame(width: 20, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        }
                        .buttonStyle(.plain)
                        .help(hex(color))
                    }
                }
            }
        }
    }

    private func colorWell(_ title: String, selection: Binding<CGColor>) -> some View {
        VStack(spacing: 3) {
            // Opacity lives in the brush settings, so colors are always opaque.
            ColorPicker(title, selection: selection, supportsOpacity: false)
                .labelsHidden()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func hex(_ color: CGColor) -> String {
        let c = color.rgba8
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }
}
