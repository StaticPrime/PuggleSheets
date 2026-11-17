#!/usr/bin/env swift
// Renders the PuggleSheets app icon at every size macOS needs.
// Usage: swift Tools/make-icons.swift PuggleSheets/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputFolder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon in a 1024x1024 design space with a top-left origin.
func drawIcon() {
    // Body: light green rounded square following the macOS icon grid (824pt body, 100pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x14532D, 0.30)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xBEEBCD).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xD5F5E0), ending: color(0xA3E2B8))!.draw(in: bodyPath, angle: 90)

    // White page with a folded corner, shifted right to leave room for the paw.
    let page = NSRect(x: 318, y: 206, width: 452, height: 592)
    let fold: CGFloat = 132
    let pagePath = NSBezierPath()
    pagePath.move(to: NSPoint(x: page.minX + 36, y: page.minY))
    pagePath.line(to: NSPoint(x: page.maxX - fold, y: page.minY))
    pagePath.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
    pagePath.line(to: NSPoint(x: page.maxX, y: page.maxY - 36))
    pagePath.appendArc(withCenter: NSPoint(x: page.maxX - 36, y: page.maxY - 36), radius: 36, startAngle: 0, endAngle: 90)
    pagePath.line(to: NSPoint(x: page.minX + 36, y: page.maxY))
    pagePath.appendArc(withCenter: NSPoint(x: page.minX + 36, y: page.maxY - 36), radius: 36, startAngle: 90, endAngle: 180)
    pagePath.line(to: NSPoint(x: page.minX, y: page.minY + 36))
    pagePath.appendArc(withCenter: NSPoint(x: page.minX + 36, y: page.minY + 36), radius: 36, startAngle: 180, endAngle: 270)
    pagePath.close()
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = color(0x14532D, 0.28)
    pageShadow.shadowBlurRadius = 20
    pageShadow.shadowOffset = NSSize(width: 0, height: -10)
    pageShadow.set()
    NSColor.white.setFill()
    pagePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: page.maxX - fold, y: page.minY))
    foldPath.line(to: NSPoint(x: page.maxX - fold, y: page.minY + fold - 28))
    foldPath.appendArc(withCenter: NSPoint(x: page.maxX - fold + 28, y: page.minY + fold - 28), radius: 28, startAngle: 180, endAngle: 90, clockwise: true)
    foldPath.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
    foldPath.close()
    color(0xC9EED6).setFill()
    foldPath.fill()

    // A green spreadsheet: a header bar, then a grid of three columns and four rows.
    let green = color(0x1E8E3E)
    let grid = NSRect(x: page.minX + 56, y: page.minY + 176, width: page.width - 112, height: 352)
    let header = NSRect(x: grid.minX, y: grid.minY, width: grid.width, height: 64)
    let headerPath = NSBezierPath(roundedRect: header, xRadius: 14, yRadius: 14)
    green.setFill()
    headerPath.fill()
    NSRect(x: header.minX, y: header.maxY - 14, width: header.width, height: 14).fill()
    let body2 = NSRect(x: grid.minX, y: header.maxY, width: grid.width, height: grid.maxY - header.maxY)
    color(0xE6F6EB).setFill()
    NSBezierPath(rect: body2).fill()
    green.setStroke()
    let outline = NSBezierPath(roundedRect: grid, xRadius: 14, yRadius: 14)
    outline.lineWidth = 14
    outline.stroke()
    let rows = 4, columns = 3
    let rowHeight = body2.height / CGFloat(rows)
    for row in 1..<rows {
        let y = body2.minY + CGFloat(row) * rowHeight
        let line = NSBezierPath()
        line.move(to: NSPoint(x: grid.minX, y: y))
        line.line(to: NSPoint(x: grid.maxX, y: y))
        line.lineWidth = 10
        line.stroke()
    }
    for column in 1..<columns {
        let x = grid.minX + CGFloat(column) * grid.width / CGFloat(columns)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: header.maxY))
        line.line(to: NSPoint(x: x, y: grid.maxY))
        line.lineWidth = 10
        line.stroke()
    }

    // Paw print badge on the left, overlapping the page's lower-left corner.
    let center = NSPoint(x: 330, y: 716)
    let pads: [NSRect] = [
        NSRect(x: center.x - 92, y: center.y - 30, width: 184, height: 150),
        NSRect(x: center.x - 152, y: center.y - 112, width: 70, height: 88),
        NSRect(x: center.x - 82, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 10, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 82, y: center.y - 112, width: 70, height: 88),
    ]
    NSGraphicsContext.saveGraphicsState()
    let pawShadow = NSShadow()
    pawShadow.shadowColor = color(0x7C2D12, 0.25)
    pawShadow.shadowBlurRadius = 12
    pawShadow.shadowOffset = NSSize(width: 0, height: -6)
    pawShadow.set()
    NSColor.white.setFill()
    for pad in pads { NSBezierPath(ovalIn: pad.insetBy(dx: -18, dy: -18)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFB020).setFill()
    for pad in pads { NSBezierPath(ovalIn: pad).fill() }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / 1024, yBy: -CGFloat(size) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: points * scale).write(to: outputFolder.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputFolder.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icons to \(outputFolder.path)")
