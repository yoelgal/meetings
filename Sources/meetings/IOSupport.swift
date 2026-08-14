import ArgumentParser
import Foundation
import MeetingsCore

/// Shared by the four commands that move meetings in and out of the store: `export`, `import`,
/// `create` and `backup`. Kept apart from `CLISupport.swift` so the read path and the IO path have
/// separate owners.

/// The two formats, and the reason they are one flag rather than two commands: you pick one
/// deliberately. `bundle` is lossless and re-importable; `md` is readable and one-way.
enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case bundle
    case md
}

/// String-backed and CaseIterable, so `--source` parses itself and `--help` lists the legal values.
extension MeetingSource: ExpressibleByArgument {}

enum IOPath {
    /// `~` expanded, relative paths resolved against the working directory. An agent hands us
    /// whatever the shell gave it.
    static func url(_ raw: String, isDirectory: Bool = false) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory)
    }

    static func mustExist(_ raw: String) throws -> URL {
        let url = url(raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("No such file: \(raw)")
        }
        return url
    }

    /// The bytes at a path, whatever kind of file it is.
    ///
    /// `String(contentsOf:)` and `FileManager.contents(atPath:)` read regular files and refuse
    /// everything else — and refuse it as *"you don't have permission to view it"*, which is a
    /// false statement about a file the caller can plainly read. Three of the things they refuse
    /// are ordinary on a command line: `/dev/null`, `/dev/stdin`, and the FIFO a shell's `<(…)`
    /// process substitution produces, which is how an agent pipes generated text into `--file`.
    ///
    /// `open(2)` reads all three, so this opens the file and reports whatever actually went wrong.
    /// A directory is the one case worth naming separately: it is a mistyped path, not a read
    /// failure, and saying "is a directory" is the whole of what the caller needs.
    static func contents(of raw: String) throws -> Data {
        let url = url(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.notFound("No such file: \(raw)")
        }
        guard !isDirectory.boolValue else {
            throw CLIError.usage("\(raw) is a directory, not a file.")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.readToEnd() ?? Data()
        } catch {
            throw CLIError.notFound("Cannot read \(raw): \((error as NSError).localizedDescription)")
        }
    }

    /// Bytes a write is going to store as text. Not `String(decoding:as: UTF8.self)`: that maps
    /// every byte it cannot read to U+FFFD, so a binary file piped in by mistake was stored as
    /// thousands of replacement characters and reported as **success** — the one shape of failure an
    /// exit code cannot warn anybody about. A UTF-8 byte-order mark is stripped rather than stored,
    /// because it is invisible in the editor that wrote it.
    static func text(_ data: Data, from source: String) throws -> String {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        guard let text = String(data: body, encoding: .utf8) else {
            throw CLIError.usage(
                "\(source) is not UTF-8 text. Save it as UTF-8, or pass the text itself."
            )
        }
        return text
    }

    /// Creates the directory an export is being written into. A `--out` that does not exist yet is
    /// ordinary — `meetings export --all --out ~/backups/2026-08-12` is how a backup gets taken.
    static func directory(_ raw: String) throws -> URL {
        let url = url(raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - JSON shapes

/// One exported meeting. `path` is what a following command opens, so it is absolute.
struct ExportedJSON: Encodable {
    let ref: String
    let title: String
    let format: String
    let path: String
    let withAudio: Bool
}

struct ExportResultJSON: Encodable {
    let count: Int
    let exported: [ExportedJSON]
}

struct ImportResultJSON: Encodable {
    let ref: String
    let title: String
    let state: String
    let folder: String?
    let segments: Int
    let notes: Int
    let audio: Bool
    /// True when the bundle's own id was already in this store, so this import made a new one. The
    /// existing meeting was not touched.
    let idCollision: Bool
    let importedFrom: String?
    let folderCreated: String?
    /// True when nothing was written.
    let dryRun: Bool
}

struct CreateResultJSON: Encodable {
    let ref: String
    let title: String
    let state: String
    let folder: String?
    let startedAt: Date?
    let endedAt: Date?
    let attendees: [Attendee]
    let segments: Int
    let audioFile: String?
    let source: String
    let importedFrom: String?
    let markdownDirectory: String?
    /// What happens next, spelled out because the state alone does not say it: a meeting at
    /// `transcribing` is sitting in the batch queue waiting for the app.
    let next: String
}

struct BackupResultJSON: Encodable {
    let path: String
    let bytes: Int
    let kept: [String]
    let pruned: Int
}
