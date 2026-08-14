#!/usr/bin/env swift
import AppKit

// Regenerates brand/banner.png: the mark, the name, nothing else.
//
//     swift scripts/make-banner.swift brand/logo.png brand/banner.png
//
// The type is SF Pro by construction rather than by name lookup. `NSFont.systemFont` *is* SF Pro on
// macOS, so this cannot silently fall back to Helvetica the way asking for "SF Pro Display" as a
// string can on a machine where the font is not installed under that exact name.

let logoPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let width = 1600, height = 480
let space = CGColorSpaceCreateDeviceRGB()

guard let logo = NSImage(contentsOfFile: logoPath)?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read \(logoPath)\n", stderr)
    exit(1)
}

// The page the mark was drawn on, sampled from its own corner, so the banner's ground matches the
// artwork and there is no edge for the mark to sit against.
var probe = [UInt8](repeating: 0, count: 4)
CGContext(data: &probe, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    .draw(logo, in: CGRect(x: 0, y: 0, width: logo.width, height: logo.height))
let page = CGColor(srgbRed: CGFloat(probe[0]) / 255, green: CGFloat(probe[1]) / 255,
                   blue: CGFloat(probe[2]) / 255, alpha: 1)

let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(page)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

let name = NSAttributedString(string: "Meetings", attributes: [
    // Large type on the system face is drawn loose by default; a touch of negative tracking is what
    // Apple's own display sizes apply.
    .font: NSFont.systemFont(ofSize: 116, weight: .semibold),
    .foregroundColor: NSColor.white,
    .kern: -2,
])

// Where the artwork actually is inside its own square. The render is a mark floating on a page with
// generous padding, so laying out against the file's edges would space the lockup by that padding
// rather than by the mark, and leave the word looking adrift. Measured, not guessed at, so a
// re-exported logo with different margins still lands right.
let inkLeft: CGFloat, inkRight: CGFloat
do {
    let w = logo.width, h = logo.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        .draw(logo, in: CGRect(x: 0, y: 0, width: w, height: h))
    let ground = (probe[0], probe[1], probe[2])
    var minX = w, maxX = 0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            // A wide threshold: the mark's glow falls off into the page, and treating the faintest
            // halo as ink would measure the glow instead of the shape.
            let delta = abs(Int(pixels[i]) - Int(ground.0)) + abs(Int(pixels[i + 1]) - Int(ground.1))
                + abs(Int(pixels[i + 2]) - Int(ground.2))
            if delta > 60 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
    }
    inkLeft = CGFloat(minX) / CGFloat(w)
    inkRight = CGFloat(maxX) / CGFloat(w)
}

// Centre mark and name as one group, so the whitespace either side is equal and the banner reads as
// a lockup rather than as two things that happen to share a canvas. The group is measured across the
// mark's ink, not its box.
let markSide: CGFloat = 340
let gap: CGFloat = 40
let nameSize = name.size()
let inkWidth = (inkRight - inkLeft) * markSide
let groupWidth = inkWidth + gap + nameSize.width
let markRect = CGRect(x: (CGFloat(width) - groupWidth) / 2 - inkLeft * markSide,
                      y: (CGFloat(height) - markSide) / 2, width: markSide, height: markSide)

// The mark, with its own square feathered away. The render carries a vignette, so a hard edge
// against a flat ground shows as a faint box however precisely the colour is matched.
let feather = CGContext(data: nil, width: Int(markSide), height: Int(markSide), bitsPerComponent: 8,
                        bytesPerRow: Int(markSide), space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: 0)!
feather.drawRadialGradient(
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
               colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1),
                        CGColor(gray: 0, alpha: 1)] as CFArray,
               locations: [0, 0.72, 1])!,
    startCenter: CGPoint(x: markSide / 2, y: markSide / 2), startRadius: 0,
    endCenter: CGPoint(x: markSide / 2, y: markSide / 2), endRadius: markSide / 2,
    options: [])
ctx.saveGState()
ctx.clip(to: markRect, mask: feather.makeImage()!)
ctx.draw(logo, in: markRect)
ctx.restoreGState()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
// Sat on the cap height rather than the font's box: the descender of "g" is the only thing below the
// baseline, and centring on the box would push the word visibly high against the mark.
let capOffset = (markSide - NSFont.systemFont(ofSize: 116, weight: .semibold).capHeight) / 2
name.draw(at: CGPoint(x: markRect.minX + inkRight * markSide + gap, y: markRect.minY + capOffset))
NSGraphicsContext.restoreGraphicsState()

try! NSBitmapImageRep(cgImage: ctx.makeImage()!)
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(width)x\(height)")
