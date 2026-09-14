// Renders the app icon: a dark squircle with a glowing cursor. Usage: swift make-icon.swift out.png
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)

// Backing squircle per Apple's 1024 template (824pt content, ~185pt radius).
let backing = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); backing.fill()
cg.restoreGState()
NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.19, alpha: 1),
                    NSColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1)])!.draw(in: backing, angle: -90)

// Soft top highlight.
cg.saveGState()
backing.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: 100, y: 624, width: 824, height: 300), angle: -90)
cg.restoreGState()

// Arrow, y-up, tip top-left.
let pts: [CGPoint] = [CGPoint(x: 0, y: 20), CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 7.5), CGPoint(x: 7, y: 1),
                      CGPoint(x: 10, y: 2.5), CGPoint(x: 7, y: 9), CGPoint(x: 12.5, y: 9)]
let arrow = NSBezierPath()
let s: CGFloat = 32
let origin = CGPoint(x: 312, y: 200)
arrow.move(to: CGPoint(x: origin.x + pts[0].x * s, y: origin.y + pts[0].y * s))
for p in pts.dropFirst() { arrow.line(to: CGPoint(x: origin.x + p.x * s, y: origin.y + p.y * s)) }
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 26

cg.saveGState()
cg.setShadow(offset: .zero, blur: 70, color: accent.withAlphaComponent(0.85).cgColor)
accent.setFill(); arrow.fill()
cg.restoreGState()
NSColor.white.setStroke(); arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
