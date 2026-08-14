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
            dependencies: ["MeetingsCore"]
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
            dependencies: ["MeetingsCore"]
        ),
        // The editor's behaviour under a real mouse. It needs the app target itself — the guard
        // tests in MeetingsCoreTests read this code as *text*, and text cannot tell you what a
        // click does. Runs headless: the window is parked offscreen and the process never
        // activates, so `swift test` steals no focus.
        .testTarget(
            name: "MeetingsAppTests",
            dependencies: ["MeetingsApp"]
        ),
    ]
)
