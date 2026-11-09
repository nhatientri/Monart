import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns PNG/JPEG data into a new single-layer canvas the size of the image.
enum ImageImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case tooLarge(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "The image could not be read."
            case let .tooLarge(width, height):
                "The image is \(width)×\(height) pixels. Canvas supports up to \(Bitmap.maxDimension) pixels per side."
            }
        }
    }

    static func makeModel(from data: Data) throws -> CanvasModel {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImportError.unreadable }
        let image = try uprightImage(from: source)

        // Transparent background so PNG transparency survives; the layer holds the image.
        let model = CanvasModel(width: image.width, height: image.height, background: nil)
        if let layer = model.layers.first {
            layer.name = "Image"
            layer.bitmap.replace(with: image, in: layer.bitmap.bounds)
        }
        return model
    }

    /// An image file's pixels (any format Image I/O reads), e.g. a file copied or dragged from Finder.
    static func image(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImportError.unreadable }
        return try uprightImage(from: source)
    }

    /// The first frame, rotated per its EXIF orientation.
    private static func uprightImage(from source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImportError.unreadable
        }
        let longestSide = max(width, height)
        guard longestSide <= Bitmap.maxDimension else {
            throw ImportError.tooLarge(width: width, height: height)
        }

        // The thumbnail API at full size is used because it applies EXIF orientation
        // (camera JPEGs are often stored sideways); the plain image API does not.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadable
        }
        return image
    }
}

extension ImageImporter {
    /// The image on a pasteboard (paste or drop), and a name for its layer when it's a file.
    ///
    /// Files come first: when you copy or drag a file in Finder, the only *image* on the
    /// pasteboard is the file's icon, so reading the pasteboard as an image would paste the
    /// icon. A copied file that isn't a readable image gives nil rather than its icon.
    static func image(from pasteboard: NSPasteboard) -> (image: CGImage, name: String?)? {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            for url in fileURLs {
                if let image = try? image(contentsOf: url) {
                    return (image, url.deletingPathExtension().lastPathComponent)
                }
            }
            return nil
        }
        guard let nsImage = NSImage(pasteboard: pasteboard),
              let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (image, nil)
    }

    /// Whether `image(from:)` is likely to find something (for drag highlighting).
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        let imageFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ])
        let anyFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return imageFiles || (!anyFiles && NSImage.canInit(with: pasteboard))
    }
}
