import CoreGraphics
import Foundation
import Observation

@Observable
final class CanvasModel {
    let width: Int
    let height: Int

    /// Bottom-most layer first. (The layers panel shows them reversed, top first.)
    var layers: [Layer]
    var activeLayerID: Layer.ID?

    /// Solid color drawn beneath all layers; `nil` means transparent (checkerboard).
    var background: CGColor?

    /// What painting, filters and clipboard commands are limited to; nil = everything.
    /// Not saved in the file, like in most paint apps.
    var selection: Selection?

    /// Number used for the next "Layer N" name.
    @ObservationIgnored private var layerCounter = 1

    /// A new canvas with one empty layer.
    convenience init(width: Int = 1920, height: Int = 1080, background: CGColor? = .white) {
        let layer = Layer(name: "Layer 1", width: width, height: height)
        self.init(width: width, height: height, background: background, layers: [layer], activeLayerID: layer.id)
    }

    /// A canvas with existing layers (bottom first), e.g. read from a file.
    init(width: Int, height: Int, background: CGColor?, layers: [Layer], activeLayerID: Layer.ID?) {
        precondition(!layers.isEmpty, "A canvas needs at least one layer")
        self.width = width
        self.height = height
        self.background = background
        self.layers = layers
        self.activeLayerID = activeLayerID ?? layers.last?.id
        self.layerCounter = layers.count
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    var activeLayer: Layer? {
        layers.first { $0.id == activeLayerID }
    }

    func index(of id: Layer.ID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    // MARK: - Layer operations
    //
    // Plain mutations. Undo is handled generically by `HistoryManager.performLayerChange`,
    // which snapshots the layer array before and after; see `CanvasDocument` for the
    // undoable entry points the UI calls.

    /// Adds a blank layer directly above the active one (or on top) and selects it.
    @discardableResult
    func addLayer() -> Layer {
        layerCounter += 1
        let layer = Layer(name: "Layer \(layerCounter)", width: width, height: height)
        let insertAt = activeLayerID.flatMap(index(of:)).map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: insertAt)
        activeLayerID = layer.id
        return layer
    }

    /// Copies a layer (pixels, visibility, opacity) directly above itself and selects the copy.
    @discardableResult
    func duplicateLayer(_ id: Layer.ID) -> Layer? {
        guard let i = index(of: id) else { return nil }
        let source = layers[i]
        let copy = Layer(name: "\(source.name) copy", width: width, height: height)
        copy.isVisible = source.isVisible
        copy.opacity = source.opacity
        copy.blendMode = source.blendMode
        copy.bitmap.copyContents(of: source.bitmap)
        layers.insert(copy, at: i + 1)
        activeLayerID = copy.id
        return copy
    }

    /// A canvas always keeps at least one layer.
    var canRemoveLayer: Bool { layers.count > 1 }

    /// Removes a layer. If it was active, the layer below it (or the new bottom) becomes active.
    func removeLayer(_ id: Layer.ID) {
        guard canRemoveLayer, let i = index(of: id) else { return }
        layers.remove(at: i)
        if activeLayerID == id {
            activeLayerID = layers[max(0, i - 1)].id
        }
    }

    /// Moves a layer up (positive, toward the top) or down (negative), clamped to the stack.
    func moveLayer(_ id: Layer.ID, by delta: Int) {
        guard let i = index(of: id) else { return }
        let j = min(max(i + delta, 0), layers.count - 1)
        guard i != j else { return }
        let layer = layers.remove(at: i)
        layers.insert(layer, at: j)
    }

    // MARK: - Canvas size

    enum ResizeMode: String, CaseIterable, Identifiable {
        /// Stretch every layer to the new size.
        case scaleImage
        /// Keep pixels at 1:1, centered; growing adds transparent space, shrinking crops.
        case keepPixels

        var id: String { rawValue }
        var title: String {
            switch self {
            case .scaleImage: "Scale image"
            case .keepPixels: "Crop or extend"
            }
        }
    }

    /// A copy of this canvas at a new size and background. Layers keep their IDs, names
    /// and settings; the selection is dropped. (Width and height are fixed per model, so the
    /// document swaps in the copy as one undo step.)
    func resized(width: Int, height: Int, mode: ResizeMode, background: CGColor?) -> CanvasModel {
        let target: CGRect
        switch mode {
        case .scaleImage:
            target = CGRect(x: 0, y: 0, width: width, height: height)
        case .keepPixels:
            target = CGRect(x: ((CGFloat(width) - CGFloat(self.width)) / 2).rounded(.down),
                            y: ((CGFloat(height) - CGFloat(self.height)) / 2).rounded(.down),
                            width: CGFloat(self.width), height: CGFloat(self.height))
        }
        let copies = layers.map { old -> Layer in
            let layer = Layer(id: old.id, name: old.name, width: width, height: height)
            layer.isVisible = old.isVisible
            layer.opacity = old.opacity
            layer.blendMode = old.blendMode
            if let image = old.bitmap.makeImage() {
                layer.bitmap.context.drawUpright(image, in: target)
            }
            return layer
        }
        let model = CanvasModel(width: width, height: height, background: background,
                                layers: copies, activeLayerID: activeLayerID)
        model.layerCounter = layerCounter
        return model
    }

    /// Reorders using offsets in **display order** (top layer first), which is what
    /// SwiftUI's `List.onMove` reports for the layers panel.
    func moveLayers(fromDisplayOffsets source: IndexSet, toDisplayOffset destination: Int) {
        var display = Array(layers.reversed())
        let moving = source.map { display[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { display.remove(at: i) }
        display.insert(contentsOf: moving, at: insertAt)
        layers = display.reversed()
    }
}
