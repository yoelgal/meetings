#!/usr/bin/env swift
import AppKit

// Draws the update banner: the mark from brand/logo.png as shaded ASCII, with the name under it in
// block letters.
//
//     swift scripts/make-ascii-banner.swift
//     swift scripts/make-ascii-banner.swift brand/logo.png 40 0.30 0.62
//
// The output is `SelfUpdate.wordmark` verbatim, so a change to the mark is carried into the terminal by
// re-running this rather than by redrawing anything.
//
// **It masks on whiteness, not brightness.** The mark is a glowing white waveform on a dark coloured
// page, and the glow is what ruins a brightness ramp: it is nearly as bright as the mark, it has no
// edge, and it bleeds across a third of the image, so every threshold either loses the mark's shape or
// fills its surroundings in. But the glow and the page are *coloured* — saturated blue, purple, pink —
// while the mark's body is white. `value × (1 − saturation)` separates exactly those: the glow drops
// out because it is coloured, not because it is dim.
//
// The ramp is the classic ASCII density ramp, so the mark keeps its shading instead of flattening into
// one silhouette, and every character in it is plain ASCII — nothing a shell would expand, nothing a
// font can be missing.

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brand/logo.png"
let columns = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 40
// `cut` is the whiteness below which a pixel is page or glow; `top` is the whiteness that counts as
// solid. The mark's body sits well under pure white, so normalising against 1.0 would draw it as a
// faint smudge.
let cut = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 0.30
let top = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4])! : 0.62

let ramp = Array(" .:-=+*#%@")

// The name, in the block-letter font whose corners are drawn with box characters. Text rather than
// artwork: the mark is a picture and gets sampled, the name is eight letters and gets set.
let name = """
███╗   ███╗███████╗███████╗████████╗██╗███╗   ██╗ ██████╗ ███████╗
████╗ ████║██╔════╝██╔════╝╚══██╔══╝██║████╗  ██║██╔════╝ ██╔════╝
██╔████╔██║█████╗  █████╗     ██║   ██║██╔██╗ ██║██║  ███╗███████╗
██║╚██╔╝██║██╔══╝  ██╔══╝     ██║   ██║██║╚██╗██║██║   ██║╚════██║
██║ ╚═╝ ██║███████╗███████╗   ██║   ██║██║ ╚████║╚██████╔╝███████║
╚═╝     ╚═╝╚══════╝╚══════╝   ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝
"""

guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read \(path)\n", stderr)
    exit(1)
}

let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

/// 0 for page and glow, 1 for the white body of the mark.
func ink(_ x: Int, _ y: Int) -> Double {
    let i = (y * width + x) * 4
    let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
    let peak = max(r, max(g, b)), trough = min(r, min(g, b))
    let saturation = peak <= 0 ? 0 : (peak - trough) / peak
    return min(max((peak * (1 - saturation) - cut) / (top - cut), 0), 1)
}

// Crop to the ink: the artwork has wide dark margins, and spending columns on them shrinks the mark
// inside the same width.
var minX = width, maxX = 0, minY = height, maxY = 0
for y in 0..<height {
    for x in 0..<width where ink(x, y) > 0.05 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fputs("whiteness cut \(cut) kept nothing\n", stderr); exit(1) }
let cropWidth = maxX - minX + 1, cropHeight = maxY - minY + 1

// A character cell is about twice as tall as it is wide, hence the halving.
let rows = max(1, Int((Double(columns) * Double(cropHeight) / Double(cropWidth) / 2).rounded()))

let nameLines = name.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let nameWidth = nameLines.map(\.count).max() ?? columns
// Centred over the name, which is the wider of the two and therefore sets the banner's width.
let markIndent = String(repeating: " ", count: max(0, (nameWidth - columns) / 2))

for row in 0..<rows {
    var line = ""
    for column in 0..<columns {
        let x0 = minX + column * cropWidth / columns
        let x1 = max(x0 + 1, minX + (column + 1) * cropWidth / columns)
        let y0 = minY + row * cropHeight / rows
        let y1 = max(y0 + 1, minY + (row + 1) * cropHeight / rows)
        var total = 0.0, count = 0
        for y in y0..<min(y1, height) {
            for x in x0..<min(x1, width) {
                total += ink(x, y)
                count += 1
            }
        }
        let level = count == 0 ? 0 : total / Double(count)
        line.append(ramp[min(ramp.count - 1, Int(level * Double(ramp.count - 1) + 0.5))])
    }
    print(String((markIndent + line).reversed().drop { $0 == " " }.reversed()))
}
print("")
nameLines.forEach { print($0) }
