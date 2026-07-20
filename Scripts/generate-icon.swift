#!/usr/bin/env swift

import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create drawing context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

// macOS-style rounded app tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -24), blur: 36, color: NSColor.black.withAlphaComponent(0.28).cgColor)
let tileRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
let tileGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.96, alpha: 1), 0),
    (NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.45, alpha: 1), 1)
)!
tileGradient.draw(in: tile, angle: -90)
context.restoreGState()

// A soft highlight keeps the tile lively in both light and dark appearances.
context.saveGState()
tile.addClip()
let highlight = NSBezierPath(ovalIn: NSRect(x: 120, y: 520, width: 780, height: 520))
NSColor.white.withAlphaComponent(0.10).setFill()
highlight.fill()
context.restoreGState()

// External drive body.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
let driveRect = NSRect(x: 226, y: 248, width: 572, height: 530)
let drive = NSBezierPath(roundedRect: driveRect, xRadius: 112, yRadius: 112)
let driveGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedWhite: 0.99, alpha: 1), 0),
    (NSColor(calibratedRed: 0.73, green: 0.82, blue: 0.92, alpha: 1), 1)
)!
driveGradient.draw(in: drive, angle: -90)
context.restoreGState()

// Slight inset gives the drive a machined aluminum edge.
let inset = NSBezierPath(roundedRect: NSRect(x: 251, y: 273, width: 522, height: 480), xRadius: 91, yRadius: 91)
NSColor.white.withAlphaComponent(0.24).setStroke()
inset.lineWidth = 5
inset.stroke()

// Mount arrow.
let arrowColor = NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.90, alpha: 1)
arrowColor.setStroke()
let stem = NSBezierPath()
stem.move(to: NSPoint(x: 512, y: 650))
stem.line(to: NSPoint(x: 512, y: 430))
stem.lineCapStyle = .round
stem.lineWidth = 46
stem.stroke()

let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 414, y: 520))
chevron.line(to: NSPoint(x: 512, y: 420))
chevron.line(to: NSPoint(x: 610, y: 520))
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.lineWidth = 46
chevron.stroke()

let mountLine = NSBezierPath()
mountLine.move(to: NSPoint(x: 386, y: 358))
mountLine.line(to: NSPoint(x: 638, y: 358))
mountLine.lineCapStyle = .round
mountLine.lineWidth = 30
mountLine.stroke()

// Read/write status light.
context.saveGState()
context.setShadow(offset: .zero, blur: 13, color: NSColor.systemMint.withAlphaComponent(0.8).cgColor)
NSColor.systemMint.setFill()
NSBezierPath(ovalIn: NSRect(x: 678, y: 319, width: 38, height: 38)).fill()
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
    fatalError("Unable to encode PNG")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
