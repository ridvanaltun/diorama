// Renders Diorama's app icon (an open box at a slight angle on a stage) to a 1024×1024 PNG.
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

// The diorama: an open box seen at a slight angle, every edge the same width, the same
// shape as the menu bar icon (MenuBarIcon in the app), scaled up.
let k = 36.0
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 188 + x * k, y: 233 + y * k) }
let front = CGRect(origin: pt(1.5, 1.5), size: CGSize(width: 11.5 * k, height: 10.5 * k))
let d = CGSize(width: 3.5 * k, height: 3 * k)
let backCorner = CGPoint(x: front.minX + d.width, y: front.minY + d.height)
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
ctx.setLineWidth(38)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.addRect(front)
// Top and right faces.
ctx.move(to: CGPoint(x: front.minX, y: front.maxY))
ctx.addLine(to: CGPoint(x: front.minX + d.width, y: front.maxY + d.height))
ctx.addLine(to: CGPoint(x: front.maxX + d.width, y: front.maxY + d.height))
ctx.addLine(to: CGPoint(x: front.maxX + d.width, y: front.minY + d.height))
ctx.addLine(to: CGPoint(x: front.maxX, y: front.minY))
ctx.move(to: CGPoint(x: front.maxX, y: front.maxY))
ctx.addLine(to: CGPoint(x: front.maxX + d.width, y: front.maxY + d.height))
// Inside, seen through the open front: the floor's left edge and the back wall.
ctx.move(to: CGPoint(x: front.minX, y: front.minY))
ctx.addLine(to: backCorner)
ctx.addLine(to: CGPoint(x: backCorner.x, y: front.maxY))
ctx.move(to: backCorner)
ctx.addLine(to: CGPoint(x: front.maxX, y: backCorner.y))
ctx.strokePath()

// A spotlight dot inside: the agent being observed.
let dot = CGRect(origin: pt(7.3, 5.7), size: CGSize(width: 3.4 * k, height: 3.4 * k))
ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 1).cgColor)
ctx.fillEllipse(in: dot)

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
