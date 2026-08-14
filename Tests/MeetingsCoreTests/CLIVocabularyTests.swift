import Foundation
import Testing

@testable import MeetingsCore

/// A term the recogniser never sees, listed everywhere as if it were in effect.
///
/// `VocabularyBiasing.minimumTermLength` drops anything under three characters before the CTC
/// spotter is even built, and nothing at the point of entry said so: `vocab add ML` stored the row,
/// `vocab list` printed it `on`, `--json` reported `"enabled": true`, and the Settings table drew it
/// active. Three surfaces agreeing that a term was working, over a transcriber that had never heard
/// of it — and the one failure mode a vocabulary feature cannot afford, because the whole point of
/// the feature is that you cannot see it working.
@Suite final class CLIVocabularyTests {
    static let cli: URL = Bundle.module.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("meetings")

    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    @discardableResult
    func run(_ arguments: String...) throws -> Run {
        try #require(FileManager.default.fileExists(atPath: Self.cli.path),
                     "the meetings CLI is not built at \(Self.cli.path)")
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = Self.cli
        process.arguments = arguments
        process.environment = ["MEETINGS_HOME": directory.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// The drift guard. The CLI cannot import the constant — it lives on an actor internal to
    /// MeetingsCore — so instead of trusting two copies of the number to stay equal, this drives the
    /// real binary at the boundary the real constant defines. One character under the recogniser's
    /// minimum is refused; the minimum itself is accepted. Change either copy alone and this fails.
    @Test func theCLIsBoundaryIsTheRecognisersBoundary() throws {
        let minimum = VocabularyBiasing.minimumTermLength
        let tooShort = String(repeating: "q", count: minimum - 1)
        let justLong = String(repeating: "q", count: minimum)

        let refused = try run("vocab", "add", tooShort)
        #expect(refused.status == 64, "\(tooShort) is under the recogniser's minimum and was accepted")
        #expect(try store.vocabularyTerms(term: tooShort).isEmpty, "a refused term must not be stored")

        let accepted = try run("vocab", "add", justLong)
        #expect(accepted.status == 0)
        #expect(try store.vocabularyTerms(term: justLong).count == 1)
    }

    /// A refusal has to say *why*, because the term looks perfectly reasonable to the person who
    /// typed it. "ML" is not a typo.
    @Test func theRefusalNamesTheReasonAndTheLength() throws {
        let result = try run("vocab", "add", "ML")
        #expect(result.status == 64)
        #expect(result.stderr.contains("recogniser ignores"), "the reason has to be on the line")
        #expect(result.stderr.contains("\(VocabularyBiasing.minimumTermLength)"),
                "the reason has to name the boundary")
        #expect(try store.vocabularyTerms(term: "ML").isEmpty)
    }

    /// And in the mode an agent branches on.
    @Test func theRefusalIsAFailingCodeInJSON() throws {
        let result = try run("vocab", "add", "ML", "--json")
        #expect(result.status == 64)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect((error["code"] as? Int) == 64)
        #expect((error["message"] as? String)?.contains("recogniser ignores") == true)
    }

    /// Whitespace does not buy length: the term is trimmed before it is measured, exactly as the
    /// biasing pass trims it.
    @Test func paddingATermWithSpacesDoesNotGetItPastTheBoundary() throws {
        #expect(try run("vocab", "add", "  ML  ").status == 64)
        #expect(try store.vocabularyTerms(term: "ML").isEmpty)
    }

    /// A real term is untouched. The guard exists to stop a lie, not to make the feature harder.
    @Test func anOrdinaryTermIsStillAccepted() throws {
        #expect(try run("vocab", "add", "ptychography").status == 0)
        #expect(try store.vocabularyTerms(term: "ptychography").count == 1)
    }

    /// `transcript edit --add-vocab` warns rather than refuses: the correction itself is good and
    /// must still land. Failing the whole edit over the vocabulary half of it would throw away the
    /// part that worked.
    @Test func aCorrectionTooShortToPromoteStillLandsAsAnEdit() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Detector housing design review"))
        let segments = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 9_000,
                              text: "we ran the em el model overnight", pass: .final),
        ])
        let id = try #require(segments.first?.id)

        let result = try run("transcript", "edit", meeting.id, "--segment", "\(id)",
                             "--text", "we ran the ML model overnight", "--add-vocab")
        #expect(result.status == 0, "the edit itself is good and has to land")
        #expect(try store.transcriptSegment(id: id)?.text == "we ran the ML model overnight")
        #expect(try store.vocabularyTerms(term: "ML").isEmpty, "a term the recogniser ignores is not stored")
        #expect(result.stderr.contains("Not added to the vocabulary"),
                "silently dropping it is the same lie one step further in")
    }

    /// The same, in JSON: the key an agent reads to find out that its `--add-vocab` did nothing.
    @Test func aCorrectionTooShortToPromoteSaysSoInJSON() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Detector housing design review"))
        let segments = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 9_000,
                              text: "we ran the em el model overnight", pass: .final),
        ])
        let id = try #require(segments.first?.id)

        let result = try run("transcript", "edit", meeting.id, "--segment", "\(id)",
                             "--text", "we ran the ML model overnight", "--add-vocab", "--json")
        #expect(result.status == 0)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(payload["vocabulary"] == nil, "nothing was added, so nothing may be reported as added")
        #expect((payload["vocabularyRefused"] as? String)?.contains("recogniser ignores") == true)
    }

    /// A correction long enough to be worth having is still promoted, so the guard has not quietly
    /// turned `--add-vocab` off.
    @Test func aCorrectionLongEnoughIsStillPromoted() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Detector housing design review"))
        let segments = try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 9_000,
                              text: "the torch zero pipeline", pass: .final),
        ])
        let id = try #require(segments.first?.id)

        let result = try run("transcript", "edit", meeting.id, "--segment", "\(id)",
                             "--text", "the Torch0 pipeline", "--add-vocab")
        #expect(result.status == 0)
        #expect(try store.vocabularyTerms(term: "Torch0").count == 1)
        #expect(!result.stderr.contains("Not added to the vocabulary"))
    }
}
