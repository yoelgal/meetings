// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Meetings",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MeetingsCore", targets: ["MeetingsCore"]),
        .executable(name: "MeetingsApp", targets: ["MeetingsApp"]),
        .executable(name: "meetings", targets: ["meetings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.5"),
        // The write-up editor, and pinned to the exact tag on purpose: swift-markdown-engine is
        // pre-1.0 and its own README says the API may change between minor releases, so `from:`
        // would let a routine resolve rewrite the editor.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "MeetingsCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "MeetingsApp",
            dependencies: [
                "MeetingsCore",
                // The editor. `MarkdownEngine` alone — the two turnkey products
                // (`MarkdownEngineCodeBlocks`, `MarkdownEngineLatex`) are what drag
                // HighlighterSwift and SwiftMath in at link time, and neither is wanted.
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ]
        ),
        .executableTarget(
            name: "meetings",
            dependencies: [
                "MeetingsCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MeetingsCoreTests",
            dependencies: [
                "MeetingsCore",
                // The round-trip suite drives the engine's own storage↔display transform directly.
                // On the *test* target and not on MeetingsCore: the library that holds the value of
                // record must not link a text editor.
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ]
        ),
        // The editor's own wiring, which needs the app target itself — the guard tests in
        // MeetingsCoreTests read this code as *text*. Nothing here constructs a window: the
        // engine's text view is the library's business, and what this checks is the bridge onto it.
        .testTarget(
            name: "MeetingsAppTests",
            dependencies: ["MeetingsApp"]
        ),
    ]
)
