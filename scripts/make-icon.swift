// Generates Resources/AppIcon.icns: dark squircle, white record ring, red dot.
// Run: swift scripts/make-icon.swift  (then build-app.sh picks it up)
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Background squircle with macOS-style margins.
let inset: CGFloat = 100
let bgRect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1),
])!.draw(in: bg, angle: -90)

// Record ring.
let center = NSPoint(x: canvas / 2, y: canvas / 2)
let ringRadius: CGFloat = 250
let ring = NSBezierPath(ovalIn: NSRect(
    x: center.x - ringRadius, y: center.y - ringRadius,
    width: ringRadius * 2, height: ringRadius * 2
))
ring.lineWidth = 46
NSColor.white.withAlphaComponent(0.92).setStroke()
ring.stroke()

// Red dot.
let dotRadius: CGFloat = 155
NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(
    x: center.x - dotRadius, y: center.y - dotRadius,
    width: dotRadius * 2, height: dotRadius * 2
)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encode failed")
}
let master = URL(fileURLWithPath: "/tmp/capture-studio-icon-1024.png")
try png.write(to: master)
print("wrote \(master.path)")
