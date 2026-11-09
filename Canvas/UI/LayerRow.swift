import SwiftUI

/// One layer in the layers panel: visibility toggle, thumbnail, name.
///
/// No gestures on the row itself: `LayersPanel` owns clicks (selection, double-click,
/// drag-to-reorder) and sets `isRenaming`, which swaps the name for an inline text field.
struct LayerRow: View {
    @Bindable var layer: Layer
    /// The layer being painted on: drawn white-on-accent.
    var isActive = false
    @Binding var isRenaming: Bool

    private var primary: Color { isActive ? .white : .primary }
    private var secondary: Color { isActive ? .white.opacity(0.8) : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                layer.isVisible.toggle()
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
                    .foregroundStyle(layer.isVisible ? primary : secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "Hide Layer" : "Show Layer")

            LayerThumbnail(layer: layer)
                .opacity(layer.isVisible ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    InlineRenameField(initialText: layer.name) { newName in
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { layer.name = name }
                        isRenaming = false
                    } onCancel: {
                        isRenaming = false
                    }
                } else {
                    Text(layer.name)
                        .lineLimit(1)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundStyle(layer.isVisible ? primary : secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Blend mode and opacity, when not the defaults.
    private var detail: String? {
        var parts: [String] = []
        if layer.blendMode != .normal { parts.append(layer.blendMode.title) }
        if layer.opacity < 1 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ThumbnailKey: Equatable {
    let layer: ObjectIdentifier
    let revision: Int
}

private struct LayerThumbnail: View {
    let layer: Layer
    /// Cached so redraws (e.g. while dragging rows) don't re-render the thumbnail.
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 40, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
        // Rebuilt only when the pixels change (stroke finished, undo/redo), or when Canvas
        // Size swaps in a resized copy of the layer (same ID, new object).
        .task(id: ThumbnailKey(layer: ObjectIdentifier(layer), revision: layer.contentRevision)) {
            image = layer.bitmap.makeThumbnail(maxPixelSize: 96)
        }
    }
}
