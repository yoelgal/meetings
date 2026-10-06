import Foundation
import Testing

@testable import MeetingsApp

/// `Appearance.isPosed` is an allowlist, so a pose override added later and not listed would let
/// that pose take the operator's focus. Read the overrides off the source and hold the list to them.
@Suite struct PoseKeysTests {
    @Test func everyOverrideTheAppReadsCountsAsAPose() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingsApp/MeetingsApp.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let read = Set(text.matches(of: /value\("(MEETINGS_[A-Z_]+)"\)/).map { String($0.output.1) })
        #expect(!read.isEmpty)
        #expect(read.subtracting(Appearance.poseKeys).isEmpty,
                "overrides missing from Appearance.poseKeys: \(read.subtracting(Appearance.poseKeys).sorted())")
    }

    @Test func realSettingsAreNotPoses() {
        #expect(!Appearance.poseKeys.contains("MEETINGS_HOME"))
        #expect(!Appearance.poseKeys.contains("MEETINGS_MD_ROOT"))
        #expect(!Appearance.poseKeys.contains("MEETINGS_DB"))
    }
}
