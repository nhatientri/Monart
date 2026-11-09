#!/usr/bin/env swift
// Draws the Canvas app icon and writes every macOS size into the asset catalog.
// Usage: swift scripts/make-app-icon.swift   (from the repository root)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: "Canvas/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The icon on a 1024-point design grid (y up), scaled to `pixels`.
func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon shape: rounded square inset from the 1024 grid, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x4338CA))
    ctx.fillPath()
    ctx.restoreGState()

    // Indigo → violet gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x3B3FD8), color(0x8E44F0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()

    // A white canvas sheet, slightly tilted.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -0.12)
    let sheet = CGRect(x: -290, y: -230, width: 580, height: 460)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x1E1B4B, 0.45))
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Three paint strokes across the sheet.
    func stroke(_ hex: UInt32, width: CGFloat, _ points: [CGPoint]) {
        let path = CGMutablePath()
        path.move(to: points[0])
        path.addCurve(to: points[3], control1: points[1], control2: points[2])
        ctx.addPath(path)
        ctx.setStrokeColor(color(hex))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    stroke(0xFF6B5B, width: 70, [CGPoint(x: -200, y: 110), CGPoint(x: -80, y: 210), CGPoint(x: 60, y: 10), CGPoint(x: 200, y: 120)])
    stroke(0xFFC93C, width: 70, [CGPoint(x: -200, y: -5), CGPoint(x: -60, y: 80), CGPoint(x: 70, y: -110), CGPoint(x: 200, y: -10)])
    stroke(0x2EC4B6, width: 70, [CGPoint(x: -200, y: -125), CGPoint(x: -70, y: -40), CGPoint(x: 60, y: -220), CGPoint(x: 200, y: -125)])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "Could not write \(url.path)")
}

// (point size, scale) pairs macOS uses.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (size, scale) in variants {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    writePNG(render(pixels: size * scale), to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(variants.count) icon sizes to \(output.path)")
