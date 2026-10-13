// Renders the AirBridge app icon (1024×1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS icon grid: rounded square inset ~10%.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 0.20, green: 0.52, blue: 0.98, alpha: 1).cgColor, NSColor(red: 0.07, green: 0.33, blue: 0.82, alpha: 1).cgColor]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.resetClip()
// Bridge arc.
ctx.translateBy(x: 0, y: 80) // optical centering
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(46); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 290, y: 430))
ctx.addQuadCurve(to: CGPoint(x: 734, y: 430), control: CGPoint(x: 512, y: 800))
ctx.strokePath()
// Up and down arrows below the arc.
ctx.setFillColor(NSColor.white.cgColor)
func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) { ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c); ctx.closePath(); ctx.fillPath() }
tri(CGPoint(x: 340, y: 360), CGPoint(x: 440, y: 360), CGPoint(x: 390, y: 260))
tri(CGPoint(x: 584, y: 260), CGPoint(x: 684, y: 260), CGPoint(x: 634, y: 360))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
