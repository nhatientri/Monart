import Foundation
import Observation

@Observable
final class Layer: Identifiable {
    let id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal

    /// Pixel contents. Not observed: the canvas view redraws from dirty rects instead.
    @ObservationIgnored let bitmap: Bitmap

    /// Bumped whenever the pixels change (stroke finished, undo/redo), so views that
    /// show the bitmap, like layer thumbnails, know to refresh.
    private(set) var contentRevision = 0

    func noteContentChanged() {
        contentRevision &+= 1
    }

    init(id: UUID = UUID(), name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.bitmap = Bitmap(width: width, height: height)
    }
}
