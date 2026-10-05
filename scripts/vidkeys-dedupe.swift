// Decides which frames of a screen recording are worth showing, by content.
//
// Why not ffmpeg's `mpdecimate`: its `hi` term keeps a frame when ANY single 8x8 block differs a lot,
// so a moving mouse cursor or a ticking menu-bar clock makes every frame "changed" and nothing gets
// dropped - measured on a real 46s recording, 221 of 221 frames survived. For UI video the useful
// question is the opposite one: how much of the SCREEN changed, ignoring a couple of tiny busy spots.
//
// So: average luminance over a coarse grid of blocks, count the blocks that moved by more than a
// threshold, and keep the frame only when that count is a large enough fraction of the screen. A
// cursor is one block in a thousand and gets ignored; a window appearing is hundreds and gets kept.
//
// Comparison is always against the last KEPT frame, not the previous frame, so a slow fade cannot
// creep past the threshold one imperceptible step at a time and never register as a change.
//
// usage: vidkeys-dedupe <blockDelta> <minFraction> <skipTopFraction> <frame.png>...
//        -> prints the 1-based index of each frame to keep, one per line
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count > 3,
      let blockDelta = Double(args[0]),
      let minFraction = Double(args[1]),
      let skipTop = Double(args[2]) else {
    FileHandle.standardError.write("usage: vidkeys-dedupe <blockDelta> <minFraction> <skipTop> <frames...>\n".data(using: .utf8)!)
    exit(2)
}
let files = Array(args.dropFirst(3))

/// Mean luminance per block, on a grid about 48 blocks wide - coarse enough that a cursor or a clock
/// digit is a single block, fine enough that a titlebar strip spans a row of them.
func blocks(_ path: String) -> [Double]? {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff), let data = bmp.bitmapData else { return nil }
    let W = bmp.pixelsWide, H = bmp.pixelsHigh
    // `samplesPerPixel` is NOT the per-pixel stride: these decode to spp=3 with bitsPerPixel=32, and
    // indexing by spp reads a smear of neighbouring channels instead of a pixel.
    let bpp = bmp.bitsPerPixel / 8, rowBytes = bmp.bytesPerRow
    let cols = 48
    let block = max(1, W / cols)
    let y0 = Int(Double(H) * skipTop)
    let rows = max(1, (H - y0) / block)
    var out = [Double](repeating: 0, count: cols * rows)
    for by in 0..<rows {
        for bx in 0..<cols {
            var sum = 0.0, n = 0.0
            // Sample every 4th pixel inside the block: the average is the point, not every pixel.
            var y = y0 + by * block
            let yEnd = min(H, y0 + (by + 1) * block)
            while y < yEnd {
                var x = bx * block
                let xEnd = min(W, (bx + 1) * block)
                while x < xEnd {
                    let o = y * rowBytes + x * bpp
                    sum += 0.2126 * Double(data[o]) + 0.7152 * Double(data[o + 1]) + 0.0722 * Double(data[o + 2])
                    n += 1
                    x += 4
                }
                y += 4
            }
            out[by * cols + bx] = n > 0 ? sum / n / 255 : 0
        }
    }
    return out
}

var lastKept: [Double]? = nil
for (i, f) in files.enumerated() {
    guard let b = blocks(f) else { continue }
    guard let prev = lastKept, prev.count == b.count else {
        print(i + 1)                       // always keep the first frame: it is the baseline
        lastKept = b
        continue
    }
    var moved = 0
    for k in 0..<b.count where abs(b[k] - prev[k]) > blockDelta { moved += 1 }
    if Double(moved) / Double(b.count) > minFraction {
        print(i + 1)
        lastKept = b
    }
}
