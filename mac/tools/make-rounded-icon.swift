#!/usr/bin/swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-rounded-icon.swift INPUT OUTPUT\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("could not read icon source: \(inputURL.path)\n".utf8))
    exit(1)
}

let canvasSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate icon canvas\n".utf8))
    exit(1)
}

guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("could not create icon graphics context\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
NSColor.clear.setFill()
canvas.fill(using: .copy)

// AppKit does not mask macOS app icons. Give the supplied square artwork the
// same inset and rounded silhouette as a modern Dock tile while preserving its
// pixels inside the tile.
let tile = NSRect(x: 64, y: 64, width: 896, height: 896)
let shape = NSBezierPath(roundedRect: tile, xRadius: 200, yRadius: 200)
shape.addClip()
source.draw(
    in: tile,
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1.0,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high.rawValue]
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode rounded icon\n".utf8))
    exit(1)
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("could not write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
