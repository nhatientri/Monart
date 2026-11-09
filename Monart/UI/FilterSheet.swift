import SwiftUI

/// Settings for one filter, previewed live on the canvas. Apply keeps it, Cancel undoes it.
struct FilterSheet: View {
    let kind: FilterKind
    let document: CanvasDocument
    let onClose: () -> Void

    @State private var parameters = FilterParameters()
    @State private var session: FilterSession?
    @State private var previewScheduled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.title).font(.title2.bold())

            if session == nil {
                Text("The selected layer is hidden. Show it to apply a filter.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    controls
                }
                if document.model.selection != nil {
                    Text("Applies to the selection only.").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session?.cancel()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    session?.commit(parameters)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            session = FilterSession(kind: kind, model: document.model, history: document.history)
            session?.preview(parameters)
        }
        .onChange(of: parameters) { _, _ in schedulePreview() }
    }

    @ViewBuilder
    private var controls: some View {
        switch kind {
        case .brightnessContrast:
            row("Brightness", $parameters.brightness, -0.5...0.5) { "\(Int(($0 * 200).rounded()))" }
            row("Contrast", $parameters.contrast, 0.25...2) { "\(Int(($0 * 100).rounded()))%" }
        case .hueSaturation:
            row("Hue", $parameters.hue, -180...180) { "\(Int($0.rounded()))°" }
            row("Saturation", $parameters.saturation, 0...2) { "\(Int(($0 * 100).rounded()))%" }
        case .gaussianBlur:
            row("Radius", $parameters.radius, 0.5...60) { String(format: "%.1f px", $0) }
        case .sharpen:
            row("Amount", $parameters.sharpness, 0...2) { "\(Int(($0 * 100).rounded()))%" }
        case .pixelate:
            row("Cell size", $parameters.cellSize, 2...100) { "\(Int($0.rounded())) px" }
        case .posterize:
            row("Levels", $parameters.levels, 2...16) { "\(Int($0.rounded()))" }
        case .invert, .grayscale:
            EmptyView()
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                     format: @escaping (Double) -> String) -> some View {
        GridRow {
            Text(title)
            Slider(value: value, in: range)
                .frame(width: 200)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// Slider drags change values faster than a full-layer filter renders; preview at most
    /// once per run-loop turn, with the latest values.
    private func schedulePreview() {
        guard !previewScheduled else { return }
        previewScheduled = true
        DispatchQueue.main.async {
            previewScheduled = false
            session?.preview(parameters)
        }
    }
}
