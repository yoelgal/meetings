#!/usr/bin/env swift
//
// Compiles Packaging/AppIcon.icon — a hand-authored macOS 26 layered icon — into the two files an
// app bundle actually needs, plus a preview to look at.
//
//   swift scripts/make-icon.swift
//     Packaging/AppIcon.car          -> Contents/Resources/Assets.car   (the layered icon)
//     Packaging/AppIcon.icns         -> Contents/Resources/AppIcon.icns (the flat fallback)
//     Packaging/AppIcon-preview.png  (nothing ships this; it is here so the icon gets looked at)
//
// WHY A .icon AND NOT JUST A .icns
// The app declares LSMinimumSystemVersion 26.0, and on 26 an .icns is a static sticker: it gets none
// of the Light, Dark, Clear or Tinted appearances the system draws for every other icon in the Dock.
// Those appearances come from a *layered* icon — a `.icon` bundle, which is a plain directory of
// `icon.json` plus SVG layers, compiled by `actool` into an `Assets.car`. The system composites the
// squircle, the material, the specular rim and the per-appearance recolouring itself; the artwork
// supplies only the flat layers. That is why Assets/*.svg contain nothing but four rectangles and no
// background, no rounded-corner mask and no shading of their own.
//
// Icon Composer.app (inside Xcode) is the GUI for this format, but nothing about it is required:
// `icon.json` is ordinary JSON and the layers are ordinary SVG, so the whole icon is diffable text
// in the repo. Icon Composer's own CLI, `ictool`, renders a `.icon` exactly as the system will —
// used below for the preview and for the fallback .icns, so both show the real composited result
// rather than a re-implementation of it.
//
// THE MARK
// `brand/logo.png`, the operator's own brand mark, drawn onto the icon grid — not redrawn. Two
// overlapping capsules, blue above and offset left, pink below and offset right, with one vertical
// beam of light through both: the product's one idea, that a meeting has two sides and Meetings
// keeps them separate. The hues are the mark's, and they are the hues ChannelStyle already gives the
// mic and system channels in the transcript.
//
// Recomposed, not resized. In the source the mark fills about 55% of the square; Apple's own icons
// fill closer to 80%, and at 32 pt beside Mail and Finder the source proportion reads timid. Every
// shape here is the source geometry — measured off logo.png, not eyeballed — scaled about the canvas
// centre by 1.1204 so the mark spans 819 of 1024 points. The 1254-point source coordinates map as
// `new = (old − 627) × 1.1204 + 512`; redraw from logo.png with that transform if the mark changes.
//
// WHAT THE RENDERER WILL AND WILL NOT DO (measured on this machine, not assumed)
// Icon Composer accepts `blend-mode`, `translucency`, `is-glass`, `specular` and `shadow` on a layer
// and, for macOS, renders none of them: every layer is flattened with normal alpha and given the
// system's own material, rim and shadow. A layer's alpha becomes its material *shape*, so a soft or
// faded edge comes back as a solid edge with a highlight on it. That is why the source's glow is not
// reproduced as a glow: the beam is painted in the colours the light actually produces — cyan across
// the blue capsule, rose across the pink, cool blue and mauve where it crosses bare plate — with the
// lit bands living inside the capsule layers so the light reads as passing through them. A beam laid
// on top would have greyed the capsules instead of lighting them.
//
// THE PLATE IS DARK, IN ALL FOUR APPEARANCES
// The mark is a beam of light. Light only reads as light against a dark ground, and both channel
// hues carry on near-black where neither carries on white. macOS 26 draws Light, Dark, Clear and
// Tinted from these same layers; the plate colour below shows in Light and Dark, and the system does
// not require a light one — Terminal, Podcasts and TV all ship dark plates. Clear and Tinted ignore
// layer colour entirely and composite from coverage alone, so what survives there is the silhouette:
// two horizontal bars crossed by one vertical. All six renditions were rendered and looked at.

import Foundation

// MARK: - Tools

/// Icon Composer ships inside Xcode and is not on the `xcrun` path, so it is located relative to the
/// selected developer directory rather than hardcoded to /Applications.
func developerDir() throws -> String {
    try run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

@discardableResult
func run(_ tool: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    // actool reports both successes and failures on stdout as a plist; keeping stderr separate means
    // a real crash still reaches the terminal.
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) exited \(process.terminationStatus)\n\(output)")
    }
    return output
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Paths

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let packaging = repoRoot.appendingPathComponent("Packaging")
let source = packaging.appendingPathComponent("AppIcon.icon")
let fm = FileManager.default

do {
    guard fm.fileExists(atPath: source.appendingPathComponent("icon.json").path) else {
        throw Failure("\(source.path)/icon.json is missing")
    }
    let developer = try developerDir()
    let ictool = "\(developer)/../Applications/Icon Composer.app/Contents/Executables/ictool"
    guard fm.isExecutableFile(atPath: ictool) else {
        throw Failure("""
            Icon Composer's ictool is not at \(ictool).
            It ships inside Xcode; `sudo xcode-select -s /Applications/Xcode.app` and retry.
            """)
    }

    // MARK: The layered icon — actool compiles the .icon into an asset catalog.
    //
    // The compile also emits a partial Info.plist naming the keys the bundle needs. It is written to
    // a temp directory and thrown away: Packaging/Info.plist carries those keys by hand, and
    // build-app.sh checks they are still there rather than merging a generated file at build time.
    let staging = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("AppIcon-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    let compiled = staging.appendingPathComponent("compiled")
    try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
    let actoolLog = try run("/usr/bin/xcrun", [
        "actool", source.path,
        "--compile", compiled.path,
        "--app-icon", "AppIcon",
        "--output-partial-info-plist", staging.appendingPathComponent("icon.plist").path,
        "--platform", "macosx",
        "--minimum-deployment-target", "26.0",
        "--output-format", "human-readable-text",
    ])
    let car = compiled.appendingPathComponent("Assets.car")
    guard fm.fileExists(atPath: car.path) else {
        throw Failure("actool produced no Assets.car\n\(actoolLog)")
    }

    // MARK: The flat fallback.
    //
    // actool emits an .icns too, but only at the two sizes it thinks a deployment target of 26 needs.
    // Rendering the full ladder through ictool instead costs one process per size and means the
    // fallback is sharp wherever it is used — and every size is composited by the system's own
    // renderer, so it matches the layered icon exactly instead of approximating it.
    let iconset = staging.appendingPathComponent("AppIcon.iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    let variants: [(name: String, size: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for variant in variants {
        try run(ictool, [
            source.path, "--export-image",
            "--output-file", iconset.appendingPathComponent("\(variant.name).png").path,
            "--platform", "macOS", "--rendition", "Default",
            "--width", "\(variant.size)", "--height", "\(variant.size)", "--scale", "1",
        ])
    }
    let icns = packaging.appendingPathComponent("AppIcon.icns")
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])

    // MARK: Install.
    let carDestination = packaging.appendingPathComponent("AppIcon.car")
    try? fm.removeItem(at: carDestination)
    try fm.copyItem(at: car, to: carDestination)

    let preview = packaging.appendingPathComponent("AppIcon-preview.png")
    try fm.removeItem(at: preview)
    try fm.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"), to: preview)

    for written in [carDestination, icns, preview] { print("wrote \(written.path)") }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
