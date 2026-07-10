// Generates a 1024x1024 app-icon PNG for zoooomrec: a rounded dark tile with a
// bright magnifier ring whose lens holds a red record dot (zoom + record).
// Pure CoreGraphics/ImageIO — no AppKit, runs headless via `swift make-icon.swift <out.png>`.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()

guard
  let ctx = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("could not create CGContext") }

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let W = CGFloat(S)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// --- Rounded tile with a top->bottom charcoal gradient -----------------------
let margin: CGFloat = 96
let tile = CGRect(x: margin, y: margin, width: W - 2 * margin, height: W - 2 * margin)
let radius: CGFloat = 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let grad = CGGradient(
  colorsSpace: cs,
  colors: [c(0.16, 0.16, 0.19), c(0.07, 0.07, 0.09)] as CFArray,
  locations: [0, 1])!
ctx.drawLinearGradient(
  grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// --- Magnifier: lens ring + handle -------------------------------------------
let light = c(0.96, 0.96, 0.97)
let lensCenter = CGPoint(x: 452, y: 596)
let lensRadius: CGFloat = 234
let ringWidth: CGFloat = 74

// Handle first so the lens ring overlaps it cleanly.
let dir = CGPoint(x: 0.7071, y: -0.7071)  // toward lower-right
let handleStart = CGPoint(
  x: lensCenter.x + dir.x * lensRadius, y: lensCenter.y + dir.y * lensRadius)
let handleEnd = CGPoint(
  x: lensCenter.x + dir.x * (lensRadius + 232), y: lensCenter.y + dir.y * (lensRadius + 232))
ctx.setLineCap(.round)
ctx.setStrokeColor(light)
ctx.setLineWidth(96)
ctx.move(to: handleStart)
ctx.addLine(to: handleEnd)
ctx.strokePath()

// Lens ring.
ctx.setLineWidth(ringWidth)
ctx.addArc(
  center: lensCenter, radius: lensRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// --- Record dot inside the lens ----------------------------------------------
ctx.setFillColor(c(1.0, 0.27, 0.23))  // system-red-ish
ctx.addArc(center: lensCenter, radius: 96, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.fillPath()

// --- Encode PNG ---------------------------------------------------------------
guard let image = ctx.makeImage() else { fatalError("makeImage failed") }
let url = URL(fileURLWithPath: outPath)
guard
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not create image destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
print("wrote \(outPath)")
