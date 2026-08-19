import Foundation
import Testing

@testable import MeetingsCore

/// The two contexts `BundleResources` has to survive. The second one cannot be reached from a test
/// process — `Bundle.main` is the test runner, not `Meetings.app` — so the `.app` layout is built on
/// disk and fed to the resolver directly.
@Suite struct BundleResourcesTests {
    /// The bare CLI and `swift test` both take the `Bundle.module` fallback.
    @Test func resolvesFromTheSwiftPMBuildDirectory() throws {
        let skill = try BundleResources.skillMarkdown()
        #expect(!skill.isEmpty)
    }

    /// The assembled app: the resource bundle sits in `Contents/Resources/`, where `Bundle.module`
    /// never looks.
    @Test func resolvesFromInsideAnAssembledApp() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BundleResourcesTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let resources = root.appendingPathComponent("Meetings.app/Contents/Resources")
        let assets = resources
            .appendingPathComponent(BundleResources.bundleName)
            .appendingPathComponent("Resources")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try "# Meetings\n\nInstalled from inside the app bundle.\n"
            .write(to: assets.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let bundle = BundleResources.locate(mainResourceURL: resources)
        #expect(bundle.bundleURL.standardizedFileURL
            == resources.appendingPathComponent(BundleResources.bundleName).standardizedFileURL)
        #expect(try BundleResources.skillMarkdown(in: bundle).hasPrefix("# Meetings"))
    }

    /// The shipped CLI, which is the branch that was missing and shipped broken. `meetings` lives at
    /// `Meetings.app/Contents/Helpers/meetings`, so its resources are one directory up and across.
    @Test func resolvesFromTheCLIInsideAnAssembledApp() throws {
        let app = try assembledApp(skill: "# Meetings\n\nFound from Contents/Helpers.\n")
        defer { try? FileManager.default.removeItem(at: app.root) }

        let cli = app.contents.appendingPathComponent("Helpers/meetings")
        // No mainResourceURL: for a bare executable that is the directory it was invoked from, not
        // the app's Resources, which is exactly why candidate 1 misses here.
        let bundle = BundleResources.locate(mainResourceURL: nil, executableURL: cli)
        #expect(try BundleResources.skillMarkdown(in: bundle).hasPrefix("# Meetings"))
    }

    /// And through the symlink the installer puts on `PATH`, which is how anyone actually runs it.
    /// Resolving that symlink is the whole of the fix: before it, `Bundle.main.resourceURL` was
    /// `~/.local/bin`, nothing was found beside it, and the lookup fell through to the `.build` path
    /// of whatever machine compiled the binary — which exists there and on no user's Mac.
    @Test func resolvesThroughThePathSymlinkTheInstallerCreates() throws {
        let fm = FileManager.default
        let app = try assembledApp(skill: "# Meetings\n\nFound through a symlink.\n")
        defer { try? fm.removeItem(at: app.root) }

        let realCLI = app.contents.appendingPathComponent("Helpers/meetings")
        try Data().write(to: realCLI)
        let bin = app.root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("meetings")
        try fm.createSymbolicLink(at: link, withDestinationURL: realCLI)

        let bundle = BundleResources.locate(mainResourceURL: bin, executableURL: link)
        #expect(try BundleResources.skillMarkdown(in: bundle).hasPrefix("# Meetings"))
    }

    /// An app with no nested bundle must fall back rather than trap, which is what makes the
    /// accessor safe to call from either executable.
    @Test func fallsBackWhenTheAppHasNoNestedBundle() throws {
        let bundle = BundleResources.locate(
            mainResourceURL: URL(fileURLWithPath: "/nonexistent/Meetings.app/Contents/Resources"))
        #expect(bundle === Bundle.module)
    }

    /// A `Contents/Helpers` path with nothing across from it falls back too, rather than returning a
    /// bundle that is not there.
    @Test func fallsBackWhenNothingSitsBesideTheExecutable() throws {
        let bundle = BundleResources.locate(
            mainResourceURL: nil,
            executableURL: URL(fileURLWithPath: "/nonexistent/Meetings.app/Contents/Helpers/meetings"))
        #expect(bundle === Bundle.module)
    }

    private struct AssembledApp { let root: URL; let contents: URL }

    private func assembledApp(skill: String) throws -> AssembledApp {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BundleResourcesTests-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Meetings.app/Contents")
        let assets = contents
            .appendingPathComponent("Resources")
            .appendingPathComponent(BundleResources.bundleName)
            .appendingPathComponent("Resources")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Helpers"),
                               withIntermediateDirectories: true)
        try skill.write(to: assets.appendingPathComponent("SKILL.md"),
                        atomically: true, encoding: .utf8)
        return AssembledApp(root: root, contents: contents)
    }
}
