#!/usr/bin/env swift

// Draws the placeholder app icon: a white "T" on a flat rounded rect.
// Run via Scripts/build-app.sh, which passes the .iconset directory to fill.
//
// Usage: swift Scripts/make-icon.swift <output.iconset>

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let background = CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1)
let foreground = CGColor(gray: 1, alpha: 1)

func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let size = CGFloat(pixels)

    // macOS icons sit in a rounded square inset from the canvas edge.
    let inset = size * 0.08
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plate.width * 0.22, cornerHeight: plate.height * 0.22, transform: nil))
    context.setFillColor(background)
    context.fillPath()

    // The "T": a horizontal bar with a stem hanging from its centre.
    let barWidth = plate.width * 0.52
    let barHeight = plate.height * 0.13
    let stemWidth = plate.width * 0.15
    let stemHeight = plate.height * 0.42
    let radius = barHeight * 0.35

    let barY = plate.midY + plate.height * 0.12
    let bar = CGRect(
        x: plate.midX - barWidth / 2,
        y: barY,
        width: barWidth,
        height: barHeight
    )
    let stem = CGRect(
        x: plate.midX - stemWidth / 2,
        y: barY - stemHeight,
        width: stemWidth,
        height: stemHeight + barHeight
    )

    context.setFillColor(foreground)
    context.addPath(CGPath(roundedRect: stem, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: image.width, height: image.height)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

for size in sizes {
    let image = drawIcon(pixels: size)
    try write(image, to: outputDirectory.appending(path: "icon_\(size)x\(size).png"))

    // Retina variants are the next size up, named for the point size below them.
    if size > 16 {
        try write(image, to: outputDirectory.appending(path: "icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}

print("Wrote iconset to \(outputDirectory.path)")
