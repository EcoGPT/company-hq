#!/usr/bin/env swift
// Draws the plain placeholder mark (the letters HQ on a blue tile) into the asset catalogs:
// both AppIcon sets and the HQLogo image. Replace the PNGs with your own art any time; this
// script only exists so the repository carries no binary art that came from somewhere else.
//
// Run from clients/apple:  swift scripts/generate-icons.swift
import AppKit

func render(size: Int, tile: Bool, rounded: Bool) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icons sit inside a margin; iOS icons fill the square (the system rounds them).
    let inset = rounded ? s * 0.1 : 0
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    if tile {
        let path = rounded
            ? NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
            : NSBezierPath(rect: rect)
        NSGradient(
            starting: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.98, alpha: 1),
            ending: NSColor(srgbRed: 0.05, green: 0.30, blue: 0.80, alpha: 1))!
            .draw(in: path, angle: -90)
    }
    let font = NSFont.systemFont(ofSize: rect.width * 0.44, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white, .kern: -rect.width * 0.01,
    ]
    let text = NSAttributedString(string: "HQ", attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
}

let mac = "Sources/macOS/Assets.xcassets"
let phone = "Sources/iOS/Assets.xcassets"
for (name, px) in [
    ("icon_16", 16), ("icon_16@2x", 32), ("icon_32", 32), ("icon_32@2x", 64), ("icon_128", 128),
    ("icon_128@2x", 256), ("icon_256", 256), ("icon_256@2x", 512), ("icon_512", 512), ("icon_512@2x", 1024),
] {
    write(render(size: px, tile: true, rounded: true), "\(mac)/AppIcon.appiconset/\(name).png")
}
write(render(size: 1024, tile: true, rounded: false), "\(phone)/AppIcon.appiconset/icon_1024.png")
for catalog in [mac, phone] {
    write(render(size: 1024, tile: true, rounded: true), "\(catalog)/HQLogo.imageset/hq-logo.png")
}
