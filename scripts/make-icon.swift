// Renders Diorama's app icon (a stage with a framed scene) to a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square background with a deep gradient.
let inset = 90.0
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)
ctx.addPath(bg)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.36, alpha: 1).cgColor, NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.70, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: inset), end: CGPoint(x: 0, y: size - inset), options: [])

// Stage floor.
ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor)
ctx.fill(CGRect(x: inset, y: inset, width: size - 2 * inset, height: 230))

// The diorama: a rounded box frame with perspective lines to a small, deep back panel.
let box = CGRect(x: 250, y: 300, width: 524, height: 430)
let back = CGRect(x: 391, y: 440, width: 241, height: 193)
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
// Lines start just inside the frame's rounded corners.
let c = 14.0
for (a, b) in [(CGPoint(x: box.minX + c, y: box.minY + c), CGPoint(x: back.minX, y: back.minY)), (CGPoint(x: box.maxX - c, y: box.minY + c), CGPoint(x: back.maxX, y: back.minY)),
               (CGPoint(x: box.minX + c, y: box.maxY - c), CGPoint(x: back.minX, y: back.maxY)), (CGPoint(x: box.maxX - c, y: box.maxY - c), CGPoint(x: back.maxX, y: back.maxY))] {
    ctx.move(to: a)
    ctx.addLine(to: b)
}
ctx.strokePath()
ctx.addPath(CGPath(roundedRect: back, cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.strokePath()
ctx.setLineWidth(34)
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
ctx.addPath(CGPath(roundedRect: box, cornerWidth: 42, cornerHeight: 42, transform: nil))
ctx.strokePath()

// A spotlight dot inside: the agent being observed, with a soft shadow on the floor.
ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.28).cgColor)
ctx.fillEllipse(in: CGRect(x: 452, y: 377, width: 120, height: 30))
ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: 458, y: 404, width: 108, height: 108))

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
