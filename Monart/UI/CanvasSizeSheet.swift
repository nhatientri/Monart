import SwiftUI

/// Image ▸ Canvas Size… (⌥⌘C, or click the size in the status bar): change the canvas's size
/// and background, and optionally make them the default for new documents.
struct CanvasSizeSheet: View {
    enum Preset: String, CaseIterable, Identifiable {
        case hd, square, a4, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hd: "1920 × 1080 (HD)"
            case .square: "2048 × 2048"
            case .a4: "A4 at 300 dpi (2480 × 3508)"
            case .custom: "Custom"
            }
        }

        var size: (width: Int, height: Int)? {
            switch self {
            case .hd: (1920, 1080)
            case .square: (2048, 2048)
            case .a4: (2480, 3508)
            case .custom: nil
            }
        }

        static func matching(width: Int, height: Int) -> Preset {
            allCases.first { $0.size.map { $0.width == width && $0.height == height } ?? false } ?? .custom
        }
    }

    let current: CanvasSetup
    let onApply: (_ setup: CanvasSetup, _ mode: CanvasModel.ResizeMode) -> Void
    let onCancel: () -> Void

    @State private var setup: CanvasSetup
    @State private var preset: Preset
    @State private var mode: CanvasModel.ResizeMode = .scaleImage
    @State private var color: CGColor
    @State private var makeDefault = false

    init(current: CanvasSetup,
         onApply: @escaping (_ setup: CanvasSetup, _ mode: CanvasModel.ResizeMode) -> Void,
         onCancel: @escaping () -> Void) {
        self.current = current
        self.onApply = onApply
        self.onCancel = onCancel
        _setup = State(initialValue: current)
        _preset = State(initialValue: .matching(width: current.width, height: current.height))
        _color = State(initialValue: CGColor(srgbRed: current.color[0], green: current.color[1],
                                             blue: current.color[2], alpha: 1))
    }

    private var sizeChanged: Bool { setup.width != current.width || setup.height != current.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Canvas Size").font(.title2.bold())

            Form {
                Picker("Size:", selection: $preset) {
                    ForEach(Preset.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: preset) { _, preset in
                    if let size = preset.size {
                        setup.width = size.width
                        setup.height = size.height
                    }
                }

                LabeledContent("Dimensions:") {
                    HStack(spacing: 6) {
                        TextField("Width", value: $setup.width, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("×")
                        TextField("Height", value: $setup.height, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("px")
                    }
                }
                .onChange(of: setup.width) { _, _ in preset = .matching(width: setup.width, height: setup.height) }
                .onChange(of: setup.height) { _, _ in preset = .matching(width: setup.width, height: setup.height) }

                Picker("Existing art:", selection: $mode) {
                    ForEach(CanvasModel.ResizeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!sizeChanged)
                .help("Scale image stretches your drawing to the new size. Crop or extend keeps it at 1:1, centered.")

                Picker("Background:", selection: $setup.background) {
                    ForEach(CanvasSetup.Background.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if setup.background == .color {
                    ColorPicker("Color:", selection: $color, supportsOpacity: false)
                }

                Toggle("Use for new canvases", isOn: $makeDefault)
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(setup.isValid ? Color.secondary : Color.red)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    var result = setup
                    if let rgb = color.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil)?.components,
                       rgb.count >= 3 {
                        result.color = rgb.prefix(3).map(Double.init)
                    }
                    if makeDefault { result.saveAsDefault() }
                    onApply(result, mode)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var footnote: String {
        guard setup.isValid else { return "Width and height must be between 1 and \(Bitmap.maxDimension) px." }
        let megabytes = Double(setup.width * setup.height * 4) / 1_048_576
        return String(format: "Each layer uses about %.0f MB of memory.", max(1, megabytes))
    }
}
