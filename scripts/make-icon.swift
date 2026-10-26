import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift scripts/make-icon.swift output.icns [preview.png]\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Cadence-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.25, green: 0.09, blue: 0.04, alpha: 0.32)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 200, yRadius: 200)
        NSColor(red: 0.63, green: 0.23, blue: 0.12, alpha: 1).setFill()
        tile.fill()
        NSShadow().set()
        guard let glaze = NSGradient(starting: NSColor(red: 0.85, green: 0.43, blue: 0.25, alpha: 1),
                                     ending: NSColor(red: 0.58, green: 0.20, blue: 0.12, alpha: 1)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        glaze.draw(in: tile, angle: -90)
        let rim = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 196, yRadius: 196)
        rim.lineWidth = 4
        NSColor.white.withAlphaComponent(0.23).setStroke()
        rim.stroke()
        let symbolShadow = NSShadow()
        symbolShadow.shadowColor = NSColor(red: 0.31, green: 0.10, blue: 0.04, alpha: 0.28)
        symbolShadow.shadowBlurRadius = 6
        symbolShadow.shadowOffset = NSSize(width: 0, height: -5)
        symbolShadow.set()
        NSColor(red: 1, green: 0.97, blue: 0.89, alpha: 1).setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = 60
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        wave.move(to: NSPoint(x: 243, y: 510))
        wave.line(to: NSPoint(x: 345, y: 510))
        wave.line(to: NSPoint(x: 413, y: 673))
        wave.line(to: NSPoint(x: 509, y: 342))
        wave.line(to: NSPoint(x: 608, y: 639))
        wave.line(to: NSPoint(x: 676, y: 510))
        wave.line(to: NSPoint(x: 781, y: 510))
        wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: iconset.appendingPathComponent(name))
        if pixels == 1024, CommandLine.arguments.count == 3 {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", destination.path, iconset.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
