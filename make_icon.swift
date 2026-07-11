// Renders the Claudius app icon (a usage gauge) to a 1024×1024 PNG.
// Offscreen bitmap so it runs headless from the command line.
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
let S = CGFloat(size)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Rounded-square background with a top-down gradient.
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let corner = S * 0.2237
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()
let bg = CGGradient(colorsSpace: cs,
                    colors: [color(0.13, 0.14, 0.19), color(0.05, 0.06, 0.09)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Gauge: 270° track with a two-tone (green → amber) usage arc.
let center = CGPoint(x: S / 2, y: S / 2)
let radius = S * 0.30
let lw = S * 0.12
ctx.setLineCap(.round)
ctx.setLineWidth(lw)

let start = CGFloat.pi * 1.25          // 225°, bottom-left
let sweep = CGFloat.pi * 1.5           // 270° total, gap at the bottom

// Track
ctx.setStrokeColor(color(1, 1, 1, 0.12))
ctx.addArc(center: center, radius: radius, startAngle: start,
           endAngle: start - sweep, clockwise: true)
ctx.strokePath()

// Usage fill (~68% of the track)
let fill = sweep * 0.68
let greenEnd = start - fill * 0.62
ctx.setStrokeColor(color(0.20, 0.80, 0.45))
ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: greenEnd, clockwise: true)
ctx.strokePath()
ctx.setStrokeColor(color(0.98, 0.70, 0.20))
ctx.addArc(center: center, radius: radius, startAngle: greenEnd, endAngle: start - fill, clockwise: true)
ctx.strokePath()

// Center dot for a bit of weight.
ctx.setFillColor(color(1, 1, 1, 0.92))
let dot = S * 0.07
ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
