// swift-tools-version: 6.2
import PackageDescription

// Seeds the demo store the film is shot against. It depends on the repo it lives in, so the demo
// content is written through `MeetingStore` exactly as the app writes it: FTS triggers fire, note
// anchors resolve, and a `- [ ]` line in a write-up is a real action rather than a string that looks
// like one. A fixture built by hand-writing SQL would photograph a store the app cannot produce.
let package = Package(
    name: "seed",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [
        // A path dependency's identity is its directory name, not the name in its manifest.
        .executableTarget(name: "seed", dependencies: [.product(name: "MeetingsCore", package: "meetings-thing")])
    ]
)
