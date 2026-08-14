import Foundation
import MarkdownEngine
import Testing

@testable import MeetingsCore

/// **The one thing the spike had to prove: a document that goes into swift-markdown-engine comes
/// back out byte for byte.**
///
/// The write-up is a `String` in a SQLite column that the CLI reads and writes. Everything above the
/// editor — autosave, the two-writer conflict banner, `meetings summary get`, the exporter — assumes
/// the editor is a lens over that string and not a document model with an opinion. An editor that
/// silently normalises anything at all is not a swap, it is a data migration nobody asked for, and
/// the first person to notice is whoever diffs their exported markdown.
///
/// The engine has exactly one transform that rewrites *characters* rather than attributes:
/// ``WikiLinkService`` keeps a `storage` form (`[[Name|<id>]]`) and a `display` form (`[[Name]]`),
/// and the text view holds the display form while the binding is meant to hold the storage form. So
/// that pair is what is driven here, over a corpus of real write-ups and the cases that break
/// transforms.
///
/// **What this cannot reach**, and it is worth saying: the editor's *typing* path. Driving that
/// needs a laid-out `NSTextView` in a window, and this package's editor tests are gated behind
/// `MEETINGS_LIVE_EDITOR=1` for the operator's sake. This is the load-and-read-back leg, which is
/// the leg the store sees on every open.
@Suite struct MarkdownEngineRoundTripTests {

    /// Storage → display → storage, which is the path a document takes from the column into the text
    /// view and back into the binding.
    private static func roundTrip(_ storage: String) -> String {
        let (display, metadata) = WikiLinkService.makeDisplayState(from: storage)
        return WikiLinkService.makeStorageState(
            from: display, existingMetadata: metadata, textStorage: nil
        ).storage
    }

    // MARK: - The corpus

    /// A write-up in the shape this app's own agent is told to produce — `SKILL.md`'s four headings,
    /// the GFM task list `meetings actions list` reads, and the inline marks an agent reaches for.
    static let writeUp = """
        # Weekly sync — 14 March

        ## What we decided

        We are shipping the **gutter editor** behind a flag, and the *pre-notes* panel stays as it
        is until the next round. Rollout is `staged`, not big-bang.

        1. Cut the release branch on Friday
        2. Soak for a week
        3. Promote, or roll back and say why

        > Sofia: "the migration is the risky half, not the editor"

        ## Actions

        - [ ] Sofia: confirm the March timeline
        - [x] anchor live notes to system audio
        - [ ] decide whether the ~~actions column~~ stays
        - a plain bullet that is not an action

        ## Open questions

        - Does the [changelog](https://example.com/changes) need a migration note?

        ## Not covered

        Pricing. Nobody from finance was on the call.
        """

    /// Documents this transform is most likely to be wrong about.
    static let adversarial: [(name: String, text: String)] = [
        ("empty", ""),
        ("no markdown at all", "Just a sentence about the call. Nothing else. No punctuation tricks."),
        ("a literal wiki link", "See [[Foo]] for the background, and [[Bar]] too."),
        ("a literal image embed", "The diagram is ![[Foo]] and the caption is under it."),
        ("a wiki link with a pipe somebody typed", "Look at [[Foo|bar]] and at [[Baz|qux|quux]]."),
        ("an unclosed wiki link", "An unclosed [[Foo and then a newline\nand [[ on its own"),
        ("brackets that are not wiki links", "An array literal: a[[0]] and a [ [ b ] ] spaced out."),
        ("emoji and combining marks", "Ship it 🚀 — Zoë said e\u{0301}clair, café\u{0301}, 👩‍👩‍👧‍👦, and 🇬🇧."),
        ("windows line endings", "# Heading\r\n\r\n- [ ] one\r\n- [x] two\r\n\r\nTrailing prose.\r\n"),
        ("a lone carriage return", "first\rsecond\r\nthird\nfourth"),
        ("trailing whitespace and blank lines", "line one   \n\n\n   \nline two\t\n\n"),
        ("no trailing newline", "one\ntwo\nthree"),
        ("a very long document", String(repeating: "\(writeUp)\n\n", count: 40)),
        ("a wiki link in a very long document",
         String(repeating: "prose prose prose\n", count: 500) + "[[Foo|1234]]\n"
            + String(repeating: "more prose\n", count: 500)),
    ]

    // MARK: - The test that matters

    @Test func everyDocumentSurvivesTheEnginesStorageAndDisplayTransformUnchanged() {
        for (name, text) in [("a real write-up", Self.writeUp)] + Self.adversarial {
            let out = Self.roundTrip(text)
            #expect(out == text, """
                \(name): the engine's wiki-link transform did not round-trip.
                in  (\(text.utf8.count) bytes): \(String(text.prefix(200)).debugDescription)
                out (\(out.utf8.count) bytes): \(String(out.prefix(200)).debugDescription)
                """)
        }
    }

    /// And on the way *in* the transform is the identity — for every document except one shape.
    ///
    /// The research said storage and display are equal byte for byte under the default
    /// ``NoOpWikiLinkResolver``. Checking rather than trusting it found the boundary: **the `|`
    /// suffix is stripped from the displayed string whether or not a resolver is wired**, because
    /// `makeDisplayState` never consults one before splitting the fragment. So a document
    /// containing `[[Foo|bar]]` is *shown* as `[[Foo]]` — five characters the author typed are not
    /// on screen, and every character offset after them differs between the text view and the
    /// column.
    ///
    /// It round-trips — the test above proves that — but only while the range-keyed metadata
    /// survives, and the engine's own comment in `+Restyling.swift` records a regression where a
    /// shifted range missed the key and the suffix was written back lost. Meetings stores no ids,
    /// so nothing in the store has this shape; a person typing a pipe inside double brackets is the
    /// only way to reach it, and this is what they would get.
    @Test func displayIsTheStoredDocumentUnlessItCarriesAPipedWikiLink() {
        for (name, text) in [("a real write-up", Self.writeUp)] + Self.adversarial {
            let (display, _) = WikiLinkService.makeDisplayState(from: text)
            if Self.hasPipedWikiLink(text) {
                #expect(display != text, """
                    \(name): this document was expected to be rewritten for display — if it no \
                    longer is, the transform changed and the caret arithmetic notes here are stale
                    """)
            } else {
                #expect(display == text, "\(name): display and storage diverged with no resolver wired")
            }
        }
    }

    /// `[[…|…]]` — the one shape whose displayed form is not its stored form.
    private static func hasPipedWikiLink(_ text: String) -> Bool {
        text.range(of: #"\[\[[^\]\r\n]*\|"#, options: .regularExpression) != nil
    }

    /// The one input where display and storage genuinely differ — and it only happens because this
    /// test asks for it.
    ///
    /// `makeDisplayState` strips the `|<id>` suffix whenever one is present, resolver or no
    /// resolver, and the way back depends entirely on the metadata map surviving the trip. It does,
    /// which is why the corpus above passes; this pins *why* rather than leaving it a coincidence.
    /// Meetings writes no ids, so nothing in the store carries this shape today.
    @Test func aStoredIdentifierIsHiddenOnDisplayAndRestoredFromTheMetadata() {
        let storage = "The note is [[Foo|9f2c]] and the picture is ![[Bar|7a1e|320]]."
        let (display, metadata) = WikiLinkService.makeDisplayState(from: storage)
        #expect(display == "The note is [[Foo]] and the picture is ![[Bar]].",
                "the id suffix is a display-time transform")
        let back = WikiLinkService.makeStorageState(
            from: display, existingMetadata: metadata, textStorage: nil
        ).storage
        #expect(back == storage, "and the metadata is what puts it back")

        // Without the metadata it is gone. That is the failure mode to watch for if this is ever
        // adopted with a real resolver: anything that drops the map drops the ids with it.
        let lost = WikiLinkService.makeStorageState(
            from: display, existingMetadata: [:], textStorage: nil
        ).storage
        #expect(lost == "The note is [[Foo]] and the picture is ![[Bar]].")
    }

    /// The resolver is what would rewrite a *label*, and Meetings does not wire one.
    ///
    /// `NoOpWikiLinkResolver` resolves nothing and — through the protocol's own default — names
    /// nothing, so the auto-sync branch in `makeDisplayState` that replaces a stored label with a
    /// target's current name can never fire. It is the difference between an editor that is a lens
    /// over a string and one that rewrites it on open.
    @Test func theDefaultResolverNeverRenamesAnything() {
        let resolver = NoOpWikiLinkResolver()
        #expect(resolver.name(forID: "9f2c") == nil)
        #expect(resolver.resolve(displayName: "Foo", range: NSRange(location: 0, length: 3)) == nil)

        // Proving it the other way round: a resolver that *does* name things changes the document,
        // which is exactly what wiring one would cost.
        let (renamed, _) = WikiLinkService.makeDisplayState(from: "[[Old name|9f2c]]") { id in
            id == "9f2c" ? "New name" : nil
        }
        #expect(renamed == "[[New name]]")
    }

    /// `rawSourceMode` is the safer configuration if the round trip above had failed, and this says
    /// what it costs: it is documented to turn off the wiki-link display transform *and* all syntax
    /// hiding, styling and smart input. So it is not a safety belt for a WYSIWYG editor — it is
    /// plain-text mode, which is a different product from the one being compared. The corpus passing
    /// is what makes it unnecessary.
    @Test func rawSourceModeIsPlainTextRatherThanASaferRenderingMode() {
        let raw = MarkdownEditorConfiguration(rawSourceMode: true)
        #expect(raw.rawSourceMode)
        #expect(!MarkdownEditorConfiguration.default.rawSourceMode,
                "the engine's shipping default renders, and that is the mode under comparison")
    }
}
