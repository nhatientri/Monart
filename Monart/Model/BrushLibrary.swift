import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Built-in brush presets plus the user's own, saved as JSON in Application Support.
/// Image tips (from "Define Brush from Selection") are stored inside their preset as PNG.
@Observable
final class BrushLibrary {
    struct Preset: Identifiable, Codable, Equatable {
        var id: UUID
        var name: String
        var settings: BrushSettings
        /// PNG of the grayscale tip, for image-tip presets.
        var tipPNG: Data?
    }

    static let shared = BrushLibrary(directory: BrushLibrary.defaultDirectory)

    let builtIns: [Preset] = BrushLibrary.makeBuiltIns()
    private(set) var custom: [Preset] = []
    @ObservationIgnored private var tipCache: [UUID: BrushTipImage] = [:]
    @ObservationIgnored private let fileURL: URL

    var all: [Preset] { builtIns + custom }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("BrushPresets.json")
        load()
    }

    func isBuiltIn(_ id: UUID) -> Bool { builtIns.contains { $0.id == id } }

    func preset(_ id: UUID?) -> Preset? { all.first { $0.id == id } }

    /// The picture for an image tip (nil for other tips or a deleted preset).
    func tipImage(for settings: BrushSettings) -> BrushTipImage? {
        guard settings.tip == .image, let id = settings.tipImageID else { return nil }
        return tipCache[id]
    }

    /// Saves `settings` as a new preset. For image tips, `tip` is stored with it.
    @discardableResult
    func addPreset(name: String, settings: BrushSettings, tip: BrushTipImage? = nil) -> Preset {
        let id = UUID()
        var settings = settings
        var png: Data?
        if let tip = tip ?? tipImage(for: settings) {
            settings.tip = .image
            settings.tipImageID = id
            png = try? DocumentFormat.pngData(tip.cgImage)
            tipCache[id] = tip
        }
        let preset = Preset(id: id, name: name, settings: settings, tipPNG: png)
        custom.append(preset)
        save()
        return preset
    }

    func delete(_ id: UUID) {
        custom.removeAll { $0.id == id }
        tipCache[id] = nil
        save()
    }

    /// Next free "Custom Brush N" name.
    func nextCustomName() -> String {
        var n = custom.count + 1
        while custom.contains(where: { $0.name == "Custom Brush \(n)" }) { n += 1 }
        return "Custom Brush \(n)"
    }

    // MARK: - Storage

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // "Canvas" was the app's name before it became Monart; kept so saved presets stay found.
        return base.appendingPathComponent("Canvas", isDirectory: true)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else { return }
        custom = presets
        for preset in presets {
            guard let png = preset.tipPNG, let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            tipCache[preset.id] = Self.grayTip(from: image)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(custom).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Monart: could not save brush presets: \(error)")
        }
    }

    /// Reads back a saved tip PNG exactly (it is already grayscale coverage).
    private static func grayTip(from image: CGImage) -> BrushTipImage? {
        let w = image.width, h = image.height
        let bytes = Selection.render(width: w, height: h) { ctx in
            ctx.interpolationQuality = .none
            ctx.drawUpright(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return BrushTipImage(width: w, height: h, coverage: bytes)
    }

    // MARK: - Built-ins

    private static func makeBuiltIns() -> [Preset] {
        func preset(_ uuid: String, _ name: String, _ configure: (inout BrushSettings) -> Void) -> Preset {
            var s = BrushSettings()
            configure(&s)
            return Preset(id: UUID(uuidString: uuid)!, name: name, settings: s, tipPNG: nil)
        }
        return [
            preset("6A1F0000-0000-4000-8000-000000000001", "Hard Round") { _ in },
            preset("6A1F0000-0000-4000-8000-000000000002", "Soft Round") { $0.hardness = 0 },
            preset("6A1F0000-0000-4000-8000-000000000003", "Square") { $0.tip = .square },
            preset("6A1F0000-0000-4000-8000-000000000004", "Calligraphy") {
                $0.roundness = 0.2; $0.angle = 45; $0.spacing = 0.05
            },
            preset("6A1F0000-0000-4000-8000-000000000005", "Marker") {
                $0.tip = .square; $0.roundness = 0.5; $0.followsStroke = true; $0.hardness = 0.8; $0.opacity = 0.7
            },
            preset("6A1F0000-0000-4000-8000-000000000006", "Chalk") {
                $0.tip = .chalk; $0.spacing = 0.15; $0.angleJitter = 1
            },
            preset("6A1F0000-0000-4000-8000-000000000007", "Spray") {
                $0.tip = .spray; $0.spacing = 0.25
            },
            preset("6A1F0000-0000-4000-8000-000000000008", "Scatter Dots") {
                $0.spacing = 1.2; $0.scatter = 1; $0.sizeJitter = 0.7
            },
        ]
    }
}
