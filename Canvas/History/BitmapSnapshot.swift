import CoreGraphics
import Foundation

/// The pixels of one pixel-aligned rect of a bitmap, captured so they can be put back later.
struct BitmapSnapshot {
    let rect: CGRect
    let data: Data

    init(of bitmap: Bitmap, rect: CGRect) {
        self.rect = rect.pixelAligned(clampedTo: bitmap.bounds)
        self.data = bitmap.pixelData(in: self.rect)
    }

    func restore(into bitmap: Bitmap) {
        guard !rect.isNull else { return }
        bitmap.setPixelData(data, in: rect)
    }

    var byteCount: Int { data.count }
}
