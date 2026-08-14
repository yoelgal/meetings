import ArgumentParser
import Foundation
import MeetingsCore

/// Custom vocabulary: the proper nouns and jargon that decide whether the transcript says
/// "ptychography" or something that poisons every summary written from it.
struct VocabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocab",
        abstract: "Terms fed to the recogniser so they survive transcription.",
        discussion: """
            A term is global or scoped to one folder. A meeting gets the global terms plus its own \
            folder's. Another folder's jargon stays out.
            """,
        subcommands: [VocabList.self, VocabAdd.self, VocabDisable.self, VocabRemove.self],
        defaultSubcommand: VocabList.self
    )
}

/// The one rule about a term that the store does not enforce and the recogniser does.
///
/// `VocabularyBiasing` drops anything shorter than three characters before the CTC spotter is even
/// built (its own `minimumTermLength`, handed straight to FluidAudio's `CustomVocabularyContext`),
/// and a two-letter term is a false-positive generator anyway. Until now nothing said so: `vocab
/// add ML` stored the row, `vocab list` printed it `on`, and the Settings table showed it active —
/// three surfaces agreeing that a term was in effect when the transcriber had never heard of it.
///
/// So it is refused where it is typed, with the reason. The number is repeated here rather than
/// imported because it lives on an actor that is internal to MeetingsCore, which this unit does not
/// own; `CLIVocabularyLengthTests` drives the real binary against the real constant and fails if
/// the two ever drift apart.
enum VocabularyRules {
    static let minimumTermLength = 3

    /// Why this term cannot be put in effect, or nil when it can. Counts the trimmed term the way
    /// the biasing pass counts it, so the answer here is the answer there.
    static func refusal(for term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < minimumTermLength else { return nil }
        return """
            "\(trimmed)" is \(trimmed.count) character\(trimmed.count == 1 ? "" : "s") long, and the \
            recogniser ignores any term under \(minimumTermLength). Add the longer form it appears \
            in instead.
            """
    }
}

struct VocabList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List vocabulary terms.",
        discussion: """
            --folder <name> lists what applies to that folder's meetings: its own terms and the \
            global ones, each labelled with its scope.
            """
    )

    @Option(name: .long, help: "Only what applies to this folder.")
    var folder: String?

    @Option(name: .long, help: "Only terms from this source: manual, attendee or correction.")
    var source: VocabSource?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let names = try context.folderNames()
            let scope = try context.folder(named: folder)

            var terms = try context.store.allVocabularyTerms()
            if let scope {
                // Global terms are included on purpose: "what vocabulary does a Torch0 meeting get"
                // is the question anybody asks here, and the answer is both scopes. The scope column
                // is what keeps that from being ambiguous.
                terms = terms.filter { $0.folderID == nil || $0.folderID == scope.id }
            }
            if let source { terms = terms.filter { $0.source == source } }

            if global.json {
                try Out.json(VocabListJSON(terms: terms.map {
                    VocabJSON($0, folder: $0.folderID.flatMap { names[$0] })
                }))
                return
            }
            guard !terms.isEmpty else {
                Out.note("No vocabulary terms\(folder.map { " for \($0)" } ?? "") yet.")
                return
            }
            Out.line(Format.columns(terms.map { term in
                [
                    term.enabled ? "on" : "off",
                    term.source.rawValue,
                    term.folderID.flatMap { names[$0] } ?? "global",
                    term.threshold.map { String(format: "%.2f", $0) } ?? "-",
                    term.term,
                ]
            }).joined(separator: "\n"))
        }
    }
}

struct VocabAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a term.",
        discussion: """
            Adding the same term in the same scope twice returns the existing term, so this is \
            safe to run from a script.
            """
    )

    @Argument(help: "The term, e.g. ptychography or Ma'agan Michael.")
    var term: String

    @Option(name: .long, help: "Scope it to this folder instead of every meeting.")
    var folder: String?

    @Option(name: .long, help: "Per-term confidence threshold between 0 and 1. Left off, the engine decides.")
    var threshold: Double?

    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let threshold, !(threshold > 0 && threshold <= 1) {
            throw ValidationError("--threshold is a confidence between 0 and 1, e.g. 0.6.")
        }
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Give me a term to add.")
        }
        if let refusal = VocabularyRules.refusal(for: term) {
            throw ValidationError(refusal)
        }
    }

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let scope = try context.folder(named: folder)
            let saved = try context.store.addVocabularyTerm(VocabularyTerm(
                term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                folderID: scope?.id,
                threshold: threshold,
                source: .manual
            ))

            if global.json {
                try Out.json(VocabJSON(saved, folder: scope?.name))
                return
            }
            Out.line("\(saved.term) (\(scope?.name ?? "global")\(saved.enabled ? "" : ", disabled"))")
        }
    }
}

struct VocabDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Turn a term off without deleting it.",
        discussion: """
            A soft-disable, so a badly auto-seeded term stays visible instead of coming back the \
            next time attendees are seeded.
            """
    )

    @OptionGroup var target: VocabTarget
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let (term, folderName) = try target.resolve(in: context)
            guard let id = term.id else { throw CLIError.notFound("\(term.term) has no id to disable") }
            _ = try context.store.setVocabularyEnabled(id: id, false)

            var disabled = term
            disabled.enabled = false
            if global.json {
                try Out.json(VocabJSON(disabled, folder: folderName))
                return
            }
            Out.line("Disabled \(term.term) (\(folderName ?? "global"))")
        }
    }
}

struct VocabRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Delete a term outright."
    )

    @OptionGroup var target: VocabTarget
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let (term, folderName) = try target.resolve(in: context)
            guard let id = term.id else { throw CLIError.notFound("\(term.term) has no id to remove") }
            _ = try context.store.deleteVocabularyTerm(id: id)

            if global.json {
                try Out.json(VocabRemovedJSON(removed: term.term, folder: folderName))
                return
            }
            Out.line("Removed \(term.term) (\(folderName ?? "global"))")
        }
    }
}

/// `disable` and `remove` take a bare term, and the same word can be a global auto-seeded name and
/// a folder-scoped correction at once. Rather than picking one, this refuses (exit 4) and names the
/// scopes — the same rule `--match` follows, for the same reason.
struct VocabTarget: ParsableArguments {
    @Argument(help: "The term.")
    var term: String

    @Option(name: .long, help: "The folder the term is scoped to, when it exists in more than one scope.")
    var folder: String?

    @Flag(name: .long, help: "The global term, when a folder-scoped one shares its name.")
    var global = false

    func resolve(in context: CLIContext) throws -> (VocabularyTerm, String?) {
        let names = try context.folderNames()
        var candidates = try context.store.vocabularyTerms(term: term)
        if let scope = try context.folder(named: folder) {
            candidates = candidates.filter { $0.folderID == scope.id }
        } else if global {
            candidates = candidates.filter { $0.folderID == nil }
        }

        guard let first = candidates.first else {
            throw CLIError.notFound("No vocabulary term \(term)\(folder.map { " in \($0)" } ?? "")")
        }
        guard candidates.count == 1 else {
            let scopes = candidates.map { $0.folderID.flatMap { names[$0] } ?? "global" }
            throw CLIError.ambiguous("""
                \(term) exists in \(candidates.count) scopes: \(scopes.joined(separator: ", ")). \
                Say which with --folder <name> or --global.
                """)
        }
        return (first, first.folderID.flatMap { names[$0] })
    }
}

private struct VocabListJSON: Encodable {
    let terms: [VocabJSON]
}

private struct VocabRemovedJSON: Encodable {
    let removed: String
    let folder: String?
}
