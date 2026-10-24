import AppKit
import Foundation

@MainActor
func encodedIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CouchKeysIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create icon bitmap"])
    }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.current = previous }
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
    NSColor(srgbRed: 10 / 255.0, green: 14 / 255.0, blue: 26 / 255.0, alpha: 1).setFill()
    background.fill()
    let monitor = NSBezierPath(roundedRect: NSRect(x: 170, y: 310, width: 684, height: 440), xRadius: 62, yRadius: 62)
    NSColor(srgbRed: 19 / 255.0, green: 24 / 255.0, blue: 40 / 255.0, alpha: 1).setFill()
    monitor.fill()
    NSColor(srgbRed: 61 / 255.0, green: 139 / 255.0, blue: 255 / 255.0, alpha: 1).setStroke()
    monitor.lineWidth = 26
    monitor.stroke()
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 512, y: 294))
    stand.line(to: NSPoint(x: 512, y: 205))
    stand.move(to: NSPoint(x: 380, y: 194))
    stand.line(to: NSPoint(x: 644, y: 194))
    stand.lineWidth = 36
    stand.lineCapStyle = .round
    stand.stroke()
    NSColor(srgbRed: 1, green: 180 / 255.0, blue: 107 / 255.0, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 785, y: 342, width: 18, height: 18)).fill()
    let label = "CK" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 150, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 243 / 255.0, green: 245 / 255.0, blue: 250 / 255.0, alpha: 1)
    ]
    let labelSize = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: (1024 - labelSize.width) / 2, y: 530 - labelSize.height / 2), withAttributes: attributes)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CouchKeysIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode icon PNG"])
    }
    return data
}

if CommandLine.arguments.count != 2 {
    fatalError("Usage: MakeIcon.swift OUTPUT.iconset")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try MainActor.assumeIsolated {
    var encodedSizes: [Int: Data] = [:]
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let data: Data
            if let existing = encodedSizes[pixels] {
                data = existing
            } else {
                data = try encodedIcon(pixels: pixels)
                encodedSizes[pixels] = data
            }
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
        }
    }
}
