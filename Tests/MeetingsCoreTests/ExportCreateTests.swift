import Foundation
import Testing

@testable import MeetingsCore

/// `meetings create --transcript-file` has two shapes and no third. What it must never do
/// is quietly pick the wrong one.
@Suite struct ExportCreateTests {
    /// A JSON transcript that misses the expected shape used to be taken as prose: the whole raw
    /// file landed as one segment attributed to "You", exit 0, state `complete`. On a two-hundred
    /// meeting migration that corrupts quietly and reads as success — and the migration is the one
    /// job nobody re-reads the output of.
    @Test(arguments: [
        #"{"segments": [{"speaker": "me", "text": "hello there"}]}"#,   // a wrapper object
        #"[{"channel": "mic", "startMs": 0}]"#,                          // no text
        #"[{"channel": "walkie", "text": "hi"}]"#,                       // not a channel
        #"[{"text": "truncated"},"#,                                     // cut off mid-array
        #"[{"startMs": "0", "text": "a string offset"}]"#,               // wrong type
    ])
    func aJSONTranscriptThatWillNotParseIsAUsageError(_ raw: String) throws {
        #expect(throws: InputError.self) {
            _ = try TranscriptDraft.parse(Data(raw.utf8), durationMs: nil)
        }
        // And the message says what to fix, not just that something failed.
        do {
            _ = try TranscriptDraft.parse(Data(raw.utf8), durationMs: nil)
            Issue.record("expected a usage error for \(raw)")
        } catch let error as InputError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("will not parse"))
            #expect(message.contains("\"channel\""), "the message names the shape it wanted")
        }
    }

    @Test("prose is still prose, leading punctuation and all")
    func plainTextStillLandsAsOneSegment() throws {
        let prose = "# Kickoff\n\nWe agreed to ship on Friday. [see the doc]"
        let drafts = try TranscriptDraft.parse(Data(prose.utf8), durationMs: 45_000)
        #expect(drafts.count == 1)
        #expect(drafts[0].channel == .mic)
        #expect(drafts[0].endMs == 45_000)
        #expect(drafts[0].text == prose)
    }

    @Test("a well-formed bundle-shaped transcript is unaffected")
    func validJSONStillParses() throws {
        let json = #"[{"channel":"system","startMs":4500,"endMs":9000,"text":"better than Tuesday"}]"#
        let drafts = try TranscriptDraft.parse(Data(json.utf8), durationMs: nil)
        #expect(drafts == [TranscriptDraft(channel: .system, startMs: 4_500, endMs: 9_000,
                                           text: "better than Tuesday")])
    }

    @Test("an empty file is nothing, not an error")
    func anEmptyFileIsNoTranscript() throws {
        #expect(try TranscriptDraft.parse(Data("   \n".utf8), durationMs: nil).isEmpty)
    }

    /// A byte-order mark is three bytes no editor shows you, and it used to turn the guard above off
    /// completely: the sniff saw U+FEFF instead of `{`, took the whole malformed file as prose, and
    /// exited 0 with a segment of raw JSON attributed to "You". Windows editors write BOMs by
    /// default, and files that have been through a Windows editor are precisely what `create` is for.
    @Test(arguments: [
        Data([0xEF, 0xBB, 0xBF]),                                  // UTF-8
        Data([0xFF, 0xFE]),                                        // UTF-16LE
        Data([0xFE, 0xFF]),                                        // UTF-16BE
    ])
    func aByteOrderMarkDoesNotDisableTheGuard(_ mark: Data) throws {
        let malformed = #"{"segments": [{"speaker": "me", "text": "hello there"}]}"#
        var data = mark
        data.append(contentsOf: encode(malformed, mark: mark))
        do {
            let drafts = try TranscriptDraft.parse(data, durationMs: nil)
            Issue.record("a BOM'd wrapper object was swallowed as \(drafts.count) prose segment(s)")
        } catch let error as InputError {
            #expect(try #require(error.errorDescription).contains("will not parse"))
        }
    }

    @Test("a BOM'd transcript that is well formed still imports, mark and all")
    func aByteOrderMarkOnValidJSONStillParses() throws {
        let json = #"[{"channel":"system","startMs":4500,"endMs":9000,"text":"better than Tuesday"}]"#
        for mark in [Data([0xEF, 0xBB, 0xBF]), Data([0xFF, 0xFE]), Data([0xFE, 0xFF])] {
            var data = mark
            data.append(contentsOf: encode(json, mark: mark))
            #expect(try TranscriptDraft.parse(data, durationMs: nil)
                == [TranscriptDraft(channel: .system, startMs: 4_500, endMs: 9_000,
                                    text: "better than Tuesday")],
                "BOM \(mark.map { String($0, radix: 16) })")
        }
    }

    /// The other two ways a first character can be something other than the one that matters.
    /// Whitespace was already handled by the trim; a shebang is genuinely not JSON and stays prose,
    /// because a file that opens `#!` is a script somebody piped, not a transcript with a typo.
    @Test("leading whitespace still finds the JSON, and a shebang is still prose")
    func whitespaceAndShebang() throws {
        let json = "\n\n  " + #"[{"text":"after some blank lines"}]"#
        #expect(try TranscriptDraft.parse(Data(json.utf8), durationMs: nil).map(\.text)
            == ["after some blank lines"])

        let script = "#!/usr/bin/env transcript\nWe agreed to ship on Friday."
        let drafts = try TranscriptDraft.parse(Data(script.utf8), durationMs: 1_000)
        #expect(drafts.map(\.text) == [script])
    }

    /// The body after the mark, in the encoding that mark announces.
    private func encode(_ text: String, mark: Data) -> Data {
        guard mark.count == 2 else { return Data(text.utf8) }
        let littleEndian = mark == Data([0xFF, 0xFE])
        return Data(text.utf16.flatMap { unit in
            littleEndian ? [UInt8(unit & 0xFF), UInt8(unit >> 8)] : [UInt8(unit >> 8), UInt8(unit & 0xFF)]
        })
    }
}
