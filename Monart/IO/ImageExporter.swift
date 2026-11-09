import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Flattens the canvas and writes it as PNG or JPEG.
enum ImageExporter {
    enum Format: String, CaseIterable, Identifiable {
        case png, jpeg

        var id: String { rawValue }
        var type: UTType { self == .png ? .png : .jpeg }
        var title: String { self == .png ? "PNG" : "JPEG" }
    }

    enum ExportError: LocalizedError {
        case renderFailed, encodeFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: "The canvas could not be rendered."
            case .encodeFailed: "The image could not be encoded."
            }
        }
    }

    /// Encoded image data for the flattened canvas.
    static func encode(_ model: CanvasModel, as format: Format, jpegQuality: Double = 0.9) throws -> Data {
        // JPEG has no alpha, so transparent areas become white instead of black.
        let matte: CGColor? = format == .jpeg ? .white : nil
        guard let image = Compositor.flatten(model, matte: matte) else { throw ExportError.renderFailed }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 format.type.identifier as CFString,
                                                                 1, nil) else {
            throw ExportError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(jpegQuality, 0), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
        return data as Data
    }

    /// Shows a save panel (as a sheet on the key window) with format and quality options.
    /// Going through `NSSavePanel` is what grants the sandboxed app write access.
    @MainActor
    static func presentExportPanel(for model: CanvasModel) {
        let options = ExportOptions()
        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [options.format.type]

        let window = NSApp.keyWindow
        let baseName = (window?.title).map { ($0 as NSString).deletingPathExtension } ?? ""
        panel.nameFieldStringValue = baseName.isEmpty ? "Untitled" : baseName

        let accessory = NSHostingView(rootView: ExportAccessoryView(options: options) { format in
            panel.allowedContentTypes = [format.type]
        })
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
        panel.accessoryView = accessory

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try encode(model, as: options.format, jpegQuality: options.jpegQuality)
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

@Observable
private final class ExportOptions {
    var format: ImageExporter.Format = .png
    var jpegQuality: Double = 0.9
}

private struct ExportAccessoryView: View {
    @Bindable var options: ExportOptions
    let onFormatChange: (ImageExporter.Format) -> Void

    var body: some View {
        Form {
            Picker("Format:", selection: $options.format) {
                ForEach(ImageExporter.Format.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            HStack {
                Slider(value: $options.jpegQuality, in: 0.1...1) { Text("Quality:") }
                    .frame(width: 200)
                Text("\(Int((options.jpegQuality * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            .disabled(options.format != .jpeg)
        }
        .padding(12)
        .onChange(of: options.format) { _, format in onFormatChange(format) }
    }
}
