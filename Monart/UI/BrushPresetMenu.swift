import SwiftUI

/// Options-bar controls for brush presets: pick one, open the tip & dynamics settings,
/// save the current brush, or delete a custom preset.
struct BrushPresetMenu: View {
    @Bindable var editor: EditorState
    @State private var library = BrushLibrary.shared
    @State private var showingSettings = false
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Section("Built-in") {
                    ForEach(library.builtIns) { preset in
                        Button(preset.name) { editor.apply(preset) }
                    }
                }
                if !library.custom.isEmpty {
                    Section("My Brushes") {
                        ForEach(library.custom) { preset in
                            Button(preset.name) { editor.apply(preset) }
                        }
                    }
                }
                Divider()
                Button("Save Current Brush…") {
                    newName = library.nextCustomName()
                    naming = true
                }
                if let id = editor.brushPresetID, !library.isBuiltIn(id), let preset = library.preset(id) {
                    Button("Delete “\(preset.name)”", role: .destructive) {
                        library.delete(id)
                        editor.brushPresetID = nil
                    }
                }
            } label: {
                Text(library.preset(editor.brushPresetID)?.name ?? "Custom")
                    .frame(width: 96, alignment: .leading)
            }
            .fixedSize()
            .help("Brush presets. Edit > Define Brush from Selection makes a brush from your own pixels.")

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Brush tip and dynamics")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                BrushSettingsView(editor: editor)
            }
        }
        .alert("Save Brush", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                let preset = library.addPreset(name: name.isEmpty ? library.nextCustomName() : name,
                                               settings: editor.brush)
                editor.brushPresetID = preset.id
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Tip shape and dynamics for the current brush.
struct BrushSettingsView: View {
    @Bindable var editor: EditorState

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Tip")
                Picker("Tip", selection: $editor.brush.tip) {
                    ForEach(BrushTip.allCases.filter { $0 != .image || editor.brush.tipImageID != nil }) {
                        Text($0.title).tag($0)
                    }
                }
                .labelsHidden()
                .gridCellColumns(2)
            }
            slider("Spacing", $editor.brush.spacing, 0.02...1.5) { "\(Int(($0 * 100).rounded()))%" }
            slider("Roundness", $editor.brush.roundness, 0.05...1) { "\(Int(($0 * 100).rounded()))%" }
            slider("Angle", $editor.brush.angle, -180...180) { "\(Int($0.rounded()))°" }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Turn with the stroke", isOn: $editor.brush.followsStroke)
                    .gridCellColumns(2)
            }
            Divider().gridCellColumns(3)
            slider("Scatter", $editor.brush.scatter, 0...2) { "\(Int(($0 * 100).rounded()))%" }
            slider("Size jitter", $editor.brush.sizeJitter, 0...1) { "\(Int(($0 * 100).rounded()))%" }
            slider("Angle jitter", $editor.brush.angleJitter, 0...1) { "\(Int(($0 * 100).rounded()))%" }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 330)
        // Editing a preset's settings makes it a one-off brush until saved.
        .onChange(of: editor.brush) { _, brush in
            if let id = editor.brushPresetID, let preset = BrushLibrary.shared.preset(id),
               !Self.sameExceptSize(preset.settings, brush) {
                editor.brushPresetID = nil
            }
        }
    }

    private static func sameExceptSize(_ a: BrushSettings, _ b: BrushSettings) -> Bool {
        var a = a
        a.size = b.size
        return a == b
    }

    private func slider(_ title: String, _ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>,
                        format: @escaping (CGFloat) -> String) -> some View {
        GridRow {
            Text(title)
            Slider(value: value, in: range)
                .frame(width: 170)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}
