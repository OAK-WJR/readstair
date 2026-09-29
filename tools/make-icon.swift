#!/usr/bin/env swift
// Generates the app icon (1024×1024; light, dark and tinted variants) into App/ReadStair/Assets.xcassets/AppIcon.appiconset/.
// Usage (from the repository root): swift tools/make-icon.swift
// Artwork: one staircase of three steps rising to the right; the top step is red — the words just above your level, the ones
// the app marks for you.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    var background: (CGFloat, CGFloat, CGFloat)
    var steps: (CGFloat, CGFloat, CGFloat)
    var top: (CGFloat, CGFloat, CGFloat)
}

let variants: [(file: String, palette: Palette)] = [
    // The top step uses the accent colour (AccentColor: #D70015, dark #ED0017)
    ("AppIcon.png", Palette(background: (0.965, 0.945, 0.906), steps: (0.23, 0.23, 0.24), top: (0xD7 / 255, 0, 0x15 / 255))),
    ("AppIcon-Dark.png", Palette(background: (0.11, 0.11, 0.12), steps: (0.93, 0.91, 0.87), top: (0xED / 255, 0, 0x17 / 255))),
    // Tinted: grayscale, because the system applies the user's chosen tint by luminance; the top step is brightest so it stands out
    // most (desaturated red would come out darker than the other steps)
    ("AppIcon-Tinted.png", Palette(background: (0, 0, 0), steps: (0.62, 0.62, 0.62), top: (1, 1, 1))),
]

// The staircase spans about 63% of the canvas width. Its mass sits low and to the right, so it is shifted up and left of centre
// to look centred. Outer corners are rounded, inner corners square, so the steps stay crisp at small sizes.
let size = 1024
let stepCount = 3, width: CGFloat = 648, rise: CGFloat = 176
let shift = CGPoint(x: -28, y: 26)
let outerRadius: CGFloat = 28

/// The staircase outline, counter-clockwise from the bottom-left corner (CoreGraphics has a bottom-left origin), and its top step.
func staircase() -> (outline: CGPath, topStep: CGRect) {
    let run = width / CGFloat(stepCount), height = rise * CGFloat(stepCount)
    let x0 = (CGFloat(size) - width) / 2 + shift.x, y0 = (CGFloat(size) - height) / 2 + shift.y
    var corners = [CGPoint(x: x0, y: y0), CGPoint(x: x0 + width, y: y0), CGPoint(x: x0 + width, y: y0 + height)]
    for step in stride(from: stepCount, through: 1, by: -1) {
        corners.append(CGPoint(x: x0 + CGFloat(step - 1) * run, y: y0 + CGFloat(step) * rise))                    // outer corner
        if step > 1 { corners.append(CGPoint(x: x0 + CGFloat(step - 1) * run, y: y0 + CGFloat(step - 1) * rise)) } // inner corner
    }
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: (corners[0].x + corners[1].x) / 2, y: corners[0].y))
    for i in 1...corners.count {
        let a = corners[i - 1], b = corners[i % corners.count], c = corners[(i + 1) % corners.count]
        let outer = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0   // a left turn on this counter-clockwise walk
        if outer { outline.addArc(tangent1End: b, tangent2End: c, radius: outerRadius) } else { outline.addLine(to: b) }
    }
    outline.closeSubpath()
    return (outline, CGRect(x: x0 + CGFloat(stepCount - 1) * run, y: y0 + CGFloat(stepCount - 1) * rise, width: run, height: rise))
}

func render(_ p: Palette) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: p.background.0, green: p.background.1, blue: p.background.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let (outline, topStep) = staircase()
    ctx.setFillColor(red: p.steps.0, green: p.steps.1, blue: p.steps.2, alpha: 1)
    ctx.addPath(outline)
    ctx.fillPath()
    // The top step is the same outline clipped to that step (grown past its outer edges), so the rounded corners match and the
    // edge runs on unbroken where the two colours meet
    ctx.clip(to: CGRect(x: topStep.minX, y: topStep.minY, width: topStep.width + 1, height: topStep.height + 1))
    ctx.setFillColor(red: p.top.0, green: p.top.1, blue: p.top.2, alpha: 1)
    ctx.addPath(outline)
    ctx.fillPath()
    return ctx.makeImage()!
}

let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "App/ReadStair/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (file, palette) in variants {
    let url = dir.appending(path: file)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(palette), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(url.path)") }
}
print("✓ \(variants.count) icons → \(dir.path)")
