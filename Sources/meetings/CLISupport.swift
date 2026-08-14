import ArgumentParser
import Foundation
import MeetingsCore

// MARK: - Exit codes

/// Agents branch on these, so they are part of the contract rather than an implementation detail
///. Every command reports failure through ``CLIFailure`` so one error can only
/// ever mean one code.
enum CLIExit {
    static let ok: Int32 = 0
    static let unexpected: Int32 = 1
    static let notFound: Int32 = 2
    static let invalidState: Int32 = 3
    static let ambiguous: Int32 = 4
    static let usage: Int32 = 64
}

/// A failure the CLI raises itself, already carrying the exit code it means.
struct CLIError: Error {
    let code: Int32
    let message: String

    static func notFound(_ message: String) -> CLIError {
        CLIError(code: CLIExit.notFound, message: message)
    }

    static func usage(_ message: String) -> CLIError {
        CLIError(code: CLIExit.usage, message: message)
    }

    /// The operation is legal, just not from where the row is standing.
    static func invalidState(_ message: String) -> CLIError {
        CLIError(code: CLIExit.invalidState, message: message)
    }

    /// A name matched more than one row and the CLI will not guess which one you meant.
    static func ambiguous(_ message: String) -> CLIError {
        CLIError(code: CLIExit.ambiguous, message: message)
    }
}

enum CLIFailure {
    /// One place where an error becomes an exit code. A `StoreError.invalidState` is a 3 whether it
    /// surfaced from `transcript edit` or from anywhere else, and nothing gets to decide otherwise.
    static func describe(_ error: Error) -> (code: Int32, message: String) {
        switch error {
        case let error as CLIError:
            return (error.code, error.message)
        case let error as RefError:
            switch error {
            case .notFound: return (CLIExit.notFound, error.description)
            case .notImplemented: return (CLIExit.unexpected, error.description)
            }
        case let error as InputError:
            // A parser in MeetingsCore cannot know about exit codes, and bad input is a 64 wherever
            // it was read — `actions set` and `transcript edit --add-vocab` both land here.
            return (CLIExit.usage, error.errorDescription ?? "\(error)")
        case let error as StoreError:
            switch error {
            case .invalidState(let reason): return (CLIExit.invalidState, reason)
            case .meetingNotFound, .folderNotFound, .segmentNotFound:
                return (CLIExit.notFound, error.errorDescription ?? "\(error)")
            }
        case let error as LocalizedError:
            return (CLIExit.unexpected, error.errorDescription ?? "\(error)")
        default:
            return (CLIExit.unexpected, PlainError.sentence(for: error))
        }
    }
}

/// One sentence for an error that came from *outside* this program — Foundation, SQLite, JSON.
///
/// String interpolation is the wrong renderer for all three, and it was the renderer. A missing
/// calendar fixture printed `Error Domain=NSCocoaErrorDomain Code=260 … UserInfo={NSFilePath=…,
/// NSURL=…, NSUnderlyingError=0x…}`; a malformed one printed `dataCorrupted(Swift.DecodingError
/// .Context(codingPath: [], debugDescription: …))`; a `--out` on a read-only volume printed the
/// whole `NSUnderlyingError` chain. Foundation writes a usable sentence for each of those and it
/// was being thrown away.
///
/// SQLite is the one that matters, because GRDB's description is not merely ugly. A constraint
/// failure names **the offending row, in full** — so a store with one orphaned segment reported
/// itself by printing that segment's transcript text at whoever ran the command. Only the message
/// clause is relayed here, cut at the first bracket and capped.
///
/// A failure *opening* the store does not come through here: ``StoreOpenError`` is a
/// `LocalizedError` and is answered by the branch above, which is where the store path, the
/// diagnosis and the snapshot to restore from are written.
enum PlainError {
    /// GRDB's `CustomNSError` domain. Matched by name rather than by type because the `meetings`
    /// target does not link GRDB — and should not start to for one string.
    private static let grdbDomain = "GRDB.DatabaseError"

    static func sentence(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == grdbDomain {
            let message = nsError.localizedFailureReason ?? "SQLite error \(nsError.code)"
            let clause = message.prefix { $0 != "[" }.trimmingCharacters(in: .whitespaces)
            return "The store rejected that: " + (clause.count > 160 ? clause.prefix(160) + "…" : clause)
        }
        // A Swift enum with no `LocalizedError` bridges to a useless "The operation couldn't be
        // completed. (Module.Thing error 0.)", so only Foundation's own domains are trusted here.
        switch nsError.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain:
            return nsError.localizedDescription
        default:
            return "\(error)"
        }
    }
}

// MARK: - Output

enum Out {
    static func line(_ text: String = "") {
        print(text)
    }

    /// Anything that is not the answer. Keeping this off stdout is what makes `--json` a single
    /// parseable value and plain output safe to pipe.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Pretty-printed on purpose: it is still exactly one JSON value, and a human reading an agent's
    /// transcript can see what the agent saw. Sorted keys keep diffs and golden files stable.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func json(_ value: some Encodable) throws {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct ErrorEnvelope: Encodable {
        struct Payload: Encodable {
            let code: Int32
            let message: String
        }
        let error: Payload
    }

    /// The `--json` failure shape. It goes to **stdout**, because an agent that asked for
    /// JSON parses stdout and would otherwise see an empty document and no reason.
    static func errorJSON(code: Int32, message: String) {
        let envelope = ErrorEnvelope(error: .init(code: code, message: message))
        if let data = try? encoder.encode(envelope) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

/// Shared by every leaf command. Later waves' write commands take the same group, so `--json`
/// behaves identically across the whole tree.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print one JSON value on stdout. Logs and warnings stay on stderr.")
    var json = false
}

/// Runs a command body and turns any failure into the right output shape and exit code.
func emitting(json: Bool, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        let failure = CLIFailure.describe(error)
        if json {
            Out.errorJSON(code: failure.code, message: failure.message)
        } else {
            Out.note("meetings: \(failure.message)")
        }
        // ExitCode is silent when it reaches the top, so the message above is the only one printed.
        throw ExitCode(failure.code)
    }
}

// MARK: - Context

/// The store, the calendar and the ref resolver, opened once per command run.
struct CLIContext {
    let store: MeetingStore
    let calendar: any CalendarSource
    let resolver: RefResolver

    static func open() throws -> CLIContext {
        let store = try openStore()
        let calendar = CalendarSources.resolved()
        return CLIContext(
            store: store,
            calendar: calendar,
            resolver: RefResolver(store: store, calendar: calendar)
        )
    }

    /// Every way opening the store can fail is diagnosed inside `MeetingsDatabase.open` and thrown
    /// as a ``StoreOpenError`` — a read-only directory, a full volume, a file that is not a
    /// database, one written by a newer build. It is a `LocalizedError`, so ``CLIFailure/describe``
    /// prints its sentence and nothing here needs to translate anything.
    private static func openStore() throws -> MeetingStore {
        MeetingStore(dbPool: try MeetingsDatabase.open())
    }

    /// Folder id → name, for the one place every listing needs it. One query beats a lookup per row.
    func folderNames() throws -> [String: String] {
        var names: [String: String] = [:]
        for folder in try store.folders() { names[folder.id] = folder.name }
        return names
    }

    /// A folder named on the command line. Missing is exit 2, not an empty list — an agent that
    /// typo'd the folder name must not read that as "no meetings in there".
    func folderID(named name: String) throws -> String {
        guard let folder = try store.folder(named: name) else {
            throw CLIError.notFound("No folder named \(name)")
        }
        return folder.id
    }

    /// Reads route through `RefResolver`, which also handles a `cal:` ref that has no row.
    func readTarget(_ raw: String) async throws -> ReadTarget {
        try await resolver.resolveForRead(MeetingRef(raw))
    }

    /// Every **write** routes through here: a `cal:` ref materialises its row first, so an
    /// agent holding an event identifier never needs a separate create step.
    ///
    /// `materialised` is reported back because it is the one thing the agent cannot infer from the
    /// result — the returned meeting looks identical whether this call made it or found it. Read
    /// before resolving rather than after: afterwards the row exists either way.
    func writeTarget(_ raw: String) async throws -> (meeting: Meeting, materialised: Bool) {
        let ref = MeetingRef(raw)
        var existed = true
        if case .calendar(let eventID) = ref {
            existed = try store.meeting(calendarEventID: eventID) != nil
        }
        return (try await resolver.resolveForWrite(ref), !existed)
    }

    /// A write that only makes sense from some states, resolved **without** materialising a row it
    /// is then going to refuse.
    ///
    /// A materialised `cal:` row is always `scheduled`, so a write that needs `recording`, `ready`
    /// or `complete` can never succeed against one — and materialising first leaves a meeting in the
    /// store for a write that never happened, which then shows up in `list` as something the user
    /// did. Reading resolves a `cal:` ref to the bare event and writes nothing, so the state can be
    /// known before anything is created: the event's row-to-be is `scheduled`, and if that is not
    /// allowed the refusal comes out with the store untouched.
    ///
    /// `refusal` gets the title and the state so the message names the meeting the user typed.
    func writeTarget(
        _ raw: String,
        allowing states: Set<MeetingState>,
        refusal: (_ title: String, _ state: MeetingState) -> CLIError
    ) async throws -> (meeting: Meeting, materialised: Bool) {
        switch try await resolver.resolveForRead(MeetingRef(raw)) {
        case .event(let event):
            guard states.contains(.scheduled) else { throw refusal(event.title, .scheduled) }
            return (try await resolver.resolveForWrite(MeetingRef(raw)), true)
        case .meeting(let meeting):
            guard states.contains(meeting.state) else { throw refusal(meeting.title, meeting.state) }
            return (meeting, false)
        }
    }

    /// The folder a `--folder` option names, or nil when it was not given. Kept apart from
    /// ``folderID(named:)`` so a command can tell "no folder asked for" from "unfiled".
    func folder(named name: String?) throws -> Folder? {
        guard let name else { return nil }
        guard let folder = try store.folder(named: name) else {
            throw CLIError.notFound("No folder named \(name)")
        }
        return folder
    }
}

// MARK: - Text input

enum TextInput {
    /// A write's text: a positional argument, `--file <path>`, or a literal `-` meaning stdin
    ///. The three are mutually exclusive.
    ///
    /// Giving none of them is a usage error rather than a read from stdin: an agent that forgot the
    /// argument would otherwise hang on a terminal nobody is going to type into, and a hang is the
    /// one failure mode an exit code cannot describe.
    static func read(_ argument: String?, file: String?, what: String) throws -> String {
        if argument != nil, file != nil {
            throw CLIError.usage(
                "Pass \(what) as text, as --file <path>, or as - for stdin. Not two at once."
            )
        }
        if let file {
            return try IOPath.text(IOPath.contents(of: file), from: file)
        }
        guard let argument else {
            throw CLIError.usage("Give me \(what): as text, with --file <path>, or as - to read stdin.")
        }
        guard argument == "-" else { return argument }
        return try IOPath.text(FileHandle.standardInput.readDataToEndOfFile(), from: "stdin")
    }

    /// Text that has to have something in it. Markdown keeps its internal shape; only the outer
    /// whitespace a here-doc or a pipe adds is trimmed.
    static func nonEmpty(_ argument: String?, file: String?, what: String) throws -> String {
        let text = try read(argument, file: file, what: what).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CLIError.usage("\(what.capitalizedFirst) came through empty.") }
        return text
    }
}

extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

// MARK: - Formatting

enum Format {
    /// `m:ss`, or `h:mm:ss` once a meeting runs over an hour. Used for every transcript offset, so a
    /// timestamp printed in one command is the timestamp you can pass back to another.
    static func offset(ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let hours = seconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// SRT wants `hh:mm:ss,mmm` — comma, not point, and the hours field is never dropped.
    static func srtTimestamp(ms: Int) -> String {
        let ms = max(0, ms)
        return String(
            format: "%02d:%02d:%02d,%03d",
            ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000
        )
    }

    static func duration(ms: Int?) -> String {
        guard let ms, ms > 0 else { return "-" }
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }

    /// Fixed format rather than locale-formatted: this output is piped into `awk` at least as often
    /// as it is read by eye, and a machine that sorts by string has to get the same answer as one
    /// that sorts by date.
    private static let dayTime = Date.VerbatimFormatStyle(
        format: """
            \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
            """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )

    static func when(_ date: Date?) -> String {
        guard let date else { return "-" }
        return dayTime.format(date)
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.0f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }

    /// Space-pads every column but the last so a listing reads as columns in a monospaced terminal
    /// and still cuts cleanly on whitespace. No box drawing, no colour, nothing a pipe has to strip.
    static func columns(_ rows: [[String]], separator: String = "  ") -> [String] {
        guard let width = rows.map(\.count).max() else { return [] }
        var widths = [Int](repeating: 0, count: width)
        for row in rows {
            for (index, cell) in row.enumerated() where index < width - 1 {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated()
                .map { index, cell in
                    index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }
                .joined(separator: separator)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// A snippet or a note printed inside a column has to stay on one line, or the column is a lie.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func attendees(_ attendees: [Attendee]) -> String {
        attendees.map { attendee in
            switch (attendee.name, attendee.email) {
            case (let name?, let email?): "\(name) <\(email)>"
            case (let name?, nil): name
            case (nil, let email?): email
            case (nil, nil): "(unnamed)"
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Parsing

enum Parse {
    /// `--since`. Accepts `2026-08-01`, a full ISO-8601 instant, or a relative window like `7d`,
    /// `36h`, `2w` — an agent asking "what did we do last week" should not have to do date maths.
    static func since(_ raw: String) throws -> Date {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        if let date = try? Date(raw, strategy: dayOnly) { return date }
        if let relative = relativeSeconds(raw) { return Date().addingTimeInterval(-relative) }
        throw CLIError.usage(
            "Cannot read \(raw) as a date. Use 2026-08-01, a full ISO-8601 instant, or a window like 7d, 36h, 2w."
        )
    }

    private static let dayOnly = Date.ParseStrategy(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)",
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .current
    )

    private static func relativeSeconds(_ raw: String) -> TimeInterval? {
        guard let unit = raw.last, let amount = Double(raw.dropLast()), amount >= 0 else { return nil }
        switch unit {
        case "h": return amount * 3600
        case "d": return amount * 86_400
        case "w": return amount * 604_800
        default: return nil
        }
    }

    /// A transcript offset: `12:30`, `1:05:00`, `750s`, `12m`, or a bare number of seconds.
    static func offsetMs(_ raw: String) throws -> Int {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        if raw.contains(":") {
            let parts = raw.split(separator: ":").map(String.init)
            guard parts.count <= 3, let numbers = try? parts.map({ try positiveInt($0, in: raw) }) else {
                throw badOffset(raw)
            }
            let seconds = numbers.reduce(0) { $0 * 60 + $1 }
            return seconds * 1000
        }
        if let unit = raw.last, "smh".contains(unit), let amount = Double(raw.dropLast()), amount >= 0 {
            let scale: Double = unit == "s" ? 1 : (unit == "m" ? 60 : 3600)
            return Int(amount * scale * 1000)
        }
        guard let seconds = Double(raw), seconds >= 0 else { throw badOffset(raw) }
        return Int(seconds * 1000)
    }

    /// `--range <start>-<end>`. Either end may be left off: `-10:00` is the first ten minutes,
    /// `45:00-` is everything from forty-five minutes in.
    static func range(_ raw: String) throws -> (startMs: Int, endMs: Int) {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw CLIError.usage("A range is <start>-<end>, for example 5:00-12:30, -10:00 or 45:00-.")
        }
        let start = parts[0].isEmpty ? 0 : try offsetMs(parts[0])
        let end = parts[1].isEmpty ? Int.max : try offsetMs(parts[1])
        guard end > start else {
            throw CLIError.usage("The end of a range has to come after its start (got \(raw)).")
        }
        return (start, end)
    }

    private static func positiveInt(_ raw: String, in whole: String) throws -> Int {
        guard let value = Int(raw), value >= 0 else { throw badOffset(whole) }
        return value
    }

    private static func badOffset(_ raw: String) -> CLIError {
        CLIError.usage("Cannot read \(raw) as a time. Use 12:30, 1:05:00, 12m, 750s or a number of seconds.")
    }
}

// MARK: - Channel labels

extension Channel {
    /// mic is whoever is sitting at this Mac; system is everything coming out of the speakers.
    ///
    /// The transcript is read by an agent asked things like "what did I commit to", so the label has
    /// to name the *speaker*, not the plumbing: `mic:` and `system:` describe where the audio came
    /// from and leave the agent to guess which one is the user.
    var speakerLabel: String {
        switch self {
        case .mic: "You"
        case .system: "Others"
        }
    }
}

// Both are string-backed and CaseIterable, so ArgumentParser gets parsing and the list of legal
// values for `--help` with no code of ours.
extension Channel: ExpressibleByArgument {}
extension MeetingState: ExpressibleByArgument {}
extension VocabSource: ExpressibleByArgument {}
