import SwiftUI

/// Under the canvas: zoom controls, the pixel under the pointer, and the canvas size.
struct StatusBar: View {
    let model: CanvasModel
    let viewport: Viewport
    /// Opens the Canvas Size sheet.
    var changeSize: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { viewport.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Button { viewport.actualSize() } label: {
                    Text("\(zoomPercent)%")
                        .monospacedDigit()
                        .frame(minWidth: 44)
                }
                .help("Actual Size (⌘1)")
                Button { viewport.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
                Button { viewport.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to Fit (⌘0)")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Label(cursorText, systemImage: "cursorarrow")
                .monospacedDigit()
                .frame(minWidth: 110, alignment: .leading)

            Divider().frame(height: 14)

            // Which layer brushes, fills and filters will change.
            Label(model.activeLayer?.name ?? "—", systemImage: "square.3.layers.3d.top.filled")
                .lineLimit(1)
                .help("The layer you're painting on")

            Spacer()

            // verbatim: no locale digit grouping ("1.920") for pixel sizes.
            Button(action: changeSize) {
                Text(verbatim: "\(model.width) × \(model.height) px")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .help("Change Canvas Size… (⌥⌘C)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var zoomPercent: String {
        let percent = viewport.zoom * 100
        return percent < 10 ? String(format: "%.1f", percent) : String(Int(percent.rounded()))
    }

    private var cursorText: String {
        guard let p = viewport.cursorLocation else { return "—" }
        return "\(Int(p.x)), \(Int(p.y))"
    }
}
