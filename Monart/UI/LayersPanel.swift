import AppKit
import SwiftUI

/// Layer list (top layer first) with add / duplicate / delete / reorder controls and the
/// active layer's opacity. Structural changes go through `CanvasDocument` so they're undoable.
///
/// A custom list rather than SwiftUI's `List`: the dragged row follows the pointer, the
/// other rows slide out of the way, and a drop counts anywhere in the list. One gesture per
/// row handles press-to-select, double-click-to-rename and drag-to-reorder, so nothing
/// competes for the mouse.
struct LayersPanel: View {
    let document: CanvasDocument
    @Bindable private var model: CanvasModel
    @State private var renamingLayerID: Layer.ID?
    @State private var drag: RowDrag?
    @State private var lastClick: RowClick?

    static let rowHeight: CGFloat = 44
    private static let listSpace = "layerList"

    private struct RowDrag {
        let id: Layer.ID
        let startIndex: Int
        var translation: CGFloat = 0
        /// False until the pointer has moved a few points, so a click doesn't nudge the row.
        var isMoving = false
    }

    private struct RowClick {
        let id: Layer.ID
        let time: Date
    }

    init(document: CanvasDocument) {
        self.document = document
        self._model = Bindable(document.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layers").font(.headline)
            layerList
            controls
            if let active = model.activeLayer {
                LayerPropertiesControl(layer: active)
            }
        }
    }

    // MARK: - List

    private var layerList: some View {
        let layers = Array(model.layers.reversed())
        let count = layers.count
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                    row(layer, index: index, count: count)
                }
            }
            .frame(height: CGFloat(count) * Self.rowHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .coordinateSpace(name: Self.listSpace)
            .padding(4)
        }
        .frame(minHeight: 140)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ layer: Layer, index: Int, count: Int) -> some View {
        let isDragged = drag?.id == layer.id && drag?.isMoving == true
        let isActive = model.activeLayerID == layer.id
        let y = yPosition(index: index, count: count)
        return LayerRow(layer: layer, isActive: isActive, isRenaming: renamingBinding(for: layer.id))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
            .background {
                ZStack {
                    if isDragged {
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                    }
                    if isActive {
                        // The layer you're painting on: solid, like a selected row in Finder.
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    }
                }
            }
            .shadow(color: .black.opacity(isDragged ? 0.25 : 0), radius: 6, y: 2)
            .contentShape(Rectangle())
            .offset(y: y)
            .zIndex(isDragged ? 1 : 0)
            // The dragged row tracks the pointer exactly; everything else glides.
            .animation(isDragged ? nil : .snappy(duration: 0.18), value: y)
            .gesture(rowGesture(for: layer, index: index, count: count))
            .contextMenu { rowMenu(for: layer) }
    }

    /// Where a row sits: its slot, or (while dragging) shifted to make room for the dragged row.
    private func yPosition(index: Int, count: Int) -> CGFloat {
        let slot = CGFloat(index) * Self.rowHeight
        guard let drag, drag.isMoving else { return slot }
        if index == drag.startIndex {
            return min(max(slot + drag.translation, 0), CGFloat(count - 1) * Self.rowHeight)
        }
        let target = targetIndex(of: drag, count: count)
        if drag.startIndex < index && index <= target { return slot - Self.rowHeight }
        if target <= index && index < drag.startIndex { return slot + Self.rowHeight }
        return slot
    }

    /// The display slot the dragged row would drop into.
    private func targetIndex(of drag: RowDrag, count: Int) -> Int {
        let position = (CGFloat(drag.startIndex) * Self.rowHeight + drag.translation) / Self.rowHeight
        return min(max(Int(position.rounded()), 0), count - 1)
    }

    private func rowGesture(for layer: Layer, index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if drag == nil {
                    // Mouse down: select right away, like a list row.
                    model.activeLayerID = layer.id
                    drag = RowDrag(id: layer.id, startIndex: index)
                }
                guard var current = drag, current.id == layer.id else { return }
                if current.isMoving || abs(value.translation.height) > 3 {
                    current.isMoving = true
                    current.translation = value.translation.height
                    drag = current
                }
            }
            .onEnded { _ in
                guard let finished = drag, finished.id == layer.id else {
                    drag = nil
                    return
                }
                drag = nil
                if finished.isMoving {
                    let target = targetIndex(of: finished, count: count)
                    if target != finished.startIndex {
                        // Offsets in List.onMove style: moving down inserts after the target.
                        document.moveLayers(fromDisplayOffsets: [finished.startIndex],
                                            toDisplayOffset: target > finished.startIndex ? target + 1 : target)
                    }
                } else {
                    registerClick(on: layer.id)
                }
            }
    }

    /// Two clicks on the same row within the system double-click interval start a rename.
    private func registerClick(on id: Layer.ID) {
        let now = Date()
        if let last = lastClick, last.id == id, now.timeIntervalSince(last.time) <= NSEvent.doubleClickInterval {
            lastClick = nil
            renamingLayerID = id
        } else {
            lastClick = RowClick(id: id, time: now)
        }
    }

    private func renamingBinding(for id: Layer.ID) -> Binding<Bool> {
        Binding(get: { renamingLayerID == id },
                set: { isOn in
                    if isOn {
                        renamingLayerID = id
                    } else if renamingLayerID == id {
                        // Only clear our own rename, not one that just started on another row.
                        renamingLayerID = nil
                    }
                })
    }

    @ViewBuilder
    private func rowMenu(for layer: Layer) -> some View {
        Button("Rename…") {
            model.activeLayerID = layer.id
            renamingLayerID = layer.id
        }
        Button(layer.isVisible ? "Hide" : "Show") { layer.isVisible.toggle() }
        Divider()
        Button("Duplicate") {
            model.activeLayerID = layer.id
            document.duplicateActiveLayer()
        }
        Button("Delete") {
            model.activeLayerID = layer.id
            document.deleteActiveLayer()
        }
        .disabled(!model.canRemoveLayer)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 2) {
            iconButton("plus", help: "New Layer (⇧⌘N)") { document.addLayer() }
            iconButton("plus.square.on.square", help: "Duplicate Layer") { document.duplicateActiveLayer() }
            iconButton("minus", help: "Delete Layer") { document.deleteActiveLayer() }
                .disabled(!model.canRemoveLayer)
            Spacer()
            iconButton("arrow.up", help: "Move Layer Up (⌘])") { document.moveActiveLayer(by: 1) }
                .disabled(!document.canMoveActiveLayerUp)
            iconButton("arrow.down", help: "Move Layer Down (⌘[)") { document.moveActiveLayer(by: -1) }
                .disabled(!document.canMoveActiveLayerDown)
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 22, height: 20)
        }
        .help(help)
    }
}

/// Blend mode and opacity of the selected layer.
private struct LayerPropertiesControl: View {
    @Bindable var layer: Layer

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Blend")
                Picker("Blend", selection: $layer.blendMode) {
                    ForEach(Array(LayerBlendMode.menuGroups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        ForEach(group) { Text($0.title).tag($0) }
                    }
                }
                .labelsHidden()
                .gridCellColumns(2)
            }
            GridRow {
                Text("Opacity")
                Slider(value: $layer.opacity, in: 0...1)
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .font(.callout)
    }
}
