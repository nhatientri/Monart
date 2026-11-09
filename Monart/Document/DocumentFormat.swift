import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The native `.canvas` file: a package (a folder Finder shows as one file).
///
///     MyDrawing.canvas/
///     ├── manifest.json     version, size, background, layer list (bottom first)
///
/// Format history: 1 = initial; 2 = adds each layer's `blendMode` (absent = normal).
///     ├── layers/<id>.png   one PNG per layer, canvas size, with alpha
///     └── thumbnail.png     flattened preview, at most 512 px
///
/// `version` lets the format change later: files from a newer version are rejected with
/// a clear error instead of being misread.
enum DocumentFormat {
    static let currentVersion = 2
    static let manifestName = "manifest.json"
    static let layersDirectory = "layers"
    static let thumbnailName = "thumbnail.png"
    static let thumbnailMaxSize = 512

    struct Manifest: Codable, Equatable {
        var version: Int
        var width: Int
        var height: Int
        /// sRGB `[r, g, b, a]`, or nil for a transparent background.
        var background: [Double]?
        var activeLayerID: UUID?
        /// Bottom-most layer first.
        var layers: [LayerEntry]
    }

    struct LayerEntry: Codable, Equatable {
        var id: UUID
        var name: String
        var visible: Bool
        var opacity: Double
        /// `LayerBlendMode` raw value; nil (version 1 files) or unknown means normal.
        var blendMode: String?
        /// Path inside the package, e.g. `layers/<id>.png`.
        var file: String
    }

    enum FormatError: LocalizedError {
        case missingManifest
        case unreadableManifest
        case newerVersion(Int)
        case invalidCanvas
        case missingLayer(String)
        case unreadableLayer(String)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .missingManifest: "The file is not a Monart drawing (manifest.json is missing)."
            case .unreadableManifest: "The document's manifest is damaged."
            case let .newerVersion(v): "This drawing was saved by a newer version of Monart (format \(v))."
            case .invalidCanvas: "The document's size or layer list is invalid."
            case let .missingLayer(name): "The pixels for layer “\(name)” are missing."
            case let .unreadableLayer(name): "The pixels for layer “\(name)” are damaged."
            case .encodeFailed: "The document could not be encoded."
            }
        }
    }

    // MARK: - Writing

    /// Everything needed to write a document, captured on the main thread. Layer images
    /// are immutable copy-on-write snapshots, so encoding can safely run in the background
    /// while you keep painting.
    struct Snapshot {
        struct LayerData {
            let entry: LayerEntry
            let image: CGImage
        }

        let manifest: Manifest
        let layers: [LayerData]

        init(_ model: CanvasModel) throws {
            layers = try model.layers.map { layer in
                guard let image = layer.bitmap.makeImage() else { throw FormatError.encodeFailed }
                let entry = LayerEntry(id: layer.id, name: layer.name, visible: layer.isVisible,
                                       opacity: layer.opacity,
                                       blendMode: layer.blendMode.rawValue,
                                       file: "\(DocumentFormat.layersDirectory)/\(layer.id.uuidString).png")
                return LayerData(entry: entry, image: image)
            }
            manifest = Manifest(version: DocumentFormat.currentVersion,
                                width: model.width, height: model.height,
                                background: model.background.flatMap(DocumentFormat.components),
                                activeLayerID: model.activeLayerID,
                                layers: layers.map(\.entry))
        }
    }

    static func fileWrapper(for snapshot: Snapshot) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(snapshot.manifest)

        var layerFiles: [String: FileWrapper] = [:]
        for layer in snapshot.layers {
            let name = (layer.entry.file as NSString).lastPathComponent
            layerFiles[name] = FileWrapper(regularFileWithContents: try pngData(layer.image))
        }

        var root: [String: FileWrapper] = [
            manifestName: FileWrapper(regularFileWithContents: manifestData),
            layersDirectory: FileWrapper(directoryWithFileWrappers: layerFiles),
        ]
        // The preview is a nicety; a failure here shouldn't stop the save.
        if let thumbnail = thumbnail(for: snapshot), let data = try? pngData(thumbnail) {
            root[thumbnailName] = FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(directoryWithFileWrappers: root)
    }

    /// Flattened, downscaled preview built from the snapshot (no access to the live model).
    static func thumbnail(for snapshot: Snapshot) -> CGImage? {
        let m = snapshot.manifest
        let scale = min(1, CGFloat(thumbnailMaxSize) / CGFloat(max(m.width, m.height)))
        let w = max(1, Int((CGFloat(m.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(m.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Bitmap.colorSpace, bitmapInfo: Bitmap.bitmapInfo) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high
        if let c = m.background, c.count == 4 {
            ctx.setFillColor(CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]))
            ctx.fill(rect)
        }
        // A plain (unflipped) context draws CGImages upright as-is.
        for layer in snapshot.layers where layer.entry.visible && layer.entry.opacity > 0 {
            ctx.setAlpha(layer.entry.opacity)
            ctx.setBlendMode(layer.entry.blendMode.flatMap(LayerBlendMode.init(rawValue:))?.cgBlendMode ?? .normal)
            ctx.draw(layer.image, in: rect)
        }
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            throw FormatError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FormatError.encodeFailed }
        return data as Data
    }

    private static func components(_ color: CGColor) -> [Double]? {
        guard let c = color.converted(to: Bitmap.colorSpace, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 4 else { return nil }
        return comps.prefix(4).map(Double.init)
    }

    // MARK: - Reading

    static func read(_ wrapper: FileWrapper) throws -> CanvasModel {
        guard wrapper.isDirectory, let manifestData = wrapper.fileWrappers?[manifestName]?.regularFileContents else {
            throw FormatError.missingManifest
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw FormatError.unreadableManifest
        }
        guard manifest.version <= currentVersion else { throw FormatError.newerVersion(manifest.version) }
        let sizeRange = 1...Bitmap.maxDimension
        guard sizeRange.contains(manifest.width), sizeRange.contains(manifest.height),
              !manifest.layers.isEmpty else { throw FormatError.invalidCanvas }

        var layers: [Layer] = []
        var seenIDs = Set<UUID>()
        for entry in manifest.layers {
            guard let data = fileContents(at: entry.file, in: wrapper) else {
                throw FormatError.missingLayer(entry.name)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == manifest.width, image.height == manifest.height else {
                throw FormatError.unreadableLayer(entry.name)
            }
            // Layer IDs must be unique for selection and undo; repair a damaged file.
            let id = seenIDs.insert(entry.id).inserted ? entry.id : UUID()
            let layer = Layer(id: id, name: entry.name, width: manifest.width, height: manifest.height)
            layer.isVisible = entry.visible
            layer.opacity = min(max(entry.opacity, 0), 1)
            layer.blendMode = entry.blendMode.flatMap(LayerBlendMode.init(rawValue:)) ?? .normal
            layer.bitmap.replace(with: image, in: layer.bitmap.bounds)
            layers.append(layer)
        }

        let background = manifest.background.flatMap { c in
            c.count == 4 ? CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]) : nil
        }
        let active = manifest.activeLayerID.flatMap { id in layers.contains { $0.id == id } ? id : nil }
        return CanvasModel(width: manifest.width, height: manifest.height, background: background,
                           layers: layers, activeLayerID: active ?? layers.last?.id)
    }

    /// Looks up `path` (e.g. `layers/x.png`) inside the package. Only real child names
    /// match, so paths like `../x` can't escape the package.
    private static func fileContents(at path: String, in root: FileWrapper) -> Data? {
        var node = root
        for component in path.split(separator: "/") {
            guard let next = node.fileWrappers?[String(component)] else { return nil }
            node = next
        }
        return node.regularFileContents
    }
}
