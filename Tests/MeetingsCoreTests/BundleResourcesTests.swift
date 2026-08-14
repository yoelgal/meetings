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

    /// An app with no nested bundle must fall back rather than trap, which is what makes the
    /// accessor safe to call from either executable.
    @Test func fallsBackWhenTheAppHasNoNestedBundle() throws {
        let bundle = BundleResources.locate(
            mainResourceURL: URL(fileURLWithPath: "/nonexistent/Meetings.app/Contents/Resources"))
        #expect(bundle === Bundle.module)
    }
}
