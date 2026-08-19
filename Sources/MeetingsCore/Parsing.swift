import Foundation

/// Input the caller got wrong, said in a sentence they can act on. The CLI maps it to exit 64.
///
/// It lives in the core rather than in the CLI so the two parsers below can too: both of them sit
/// in front of a write, and a parser in front of a write is the last place to save a file by
/// leaving it where no test can reach it.
public enum InputError: Error, LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let problem): problem
        }
    }
}

// MARK: - actions set

/// The `actions set` payload, validated rather than trusted.
///
/// `JSONDecoder` alone would do most of this, but its message for a mistyped key is a `CodingPath`
/// an agent cannot act on — and silently dropping an `assignee` field the agent meant as `owner`
/// loses the data with no error at all. So the shape is checked by hand and every failure names the
/// element it came from.
public enum ActionsInput {
    public static let allowedKeys: Set<String> = ["text", "owner", "due", "done"]

    public static func parse(_ raw: String) throws -> [Action] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw usage("it came through empty") }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])
        } catch {
            throw usage("that is not valid JSON (\(error.localizedDescription))")
        }
        guard let elements = parsed as? [Any] else {
            throw usage("the top level has to be an array")
        }

        return try elements.enumerated().map { index, element in
            guard let object = element as? [String: Any] else {
                throw usage("item \(index + 1) is not an object")
            }
            let unknown = Set(object.keys).subtracting(allowedKeys).sorted()
            guard unknown.isEmpty else {
                throw usage("item \(index + 1) has \(unknown.count == 1 ? "an unknown key" : "unknown keys") "
                    + unknown.joined(separator: ", "))
            }
            guard let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw usage("item \(index + 1) needs a non-empty text")
            }
            return Action(
                text: text,
                owner: try optionalString(object["owner"], key: "owner", index: index),
                due: try optionalString(object["due"], key: "due", index: index),
                done: try optionalBool(object["done"], index: index)
            )
        }
    }

    private static func optionalString(_ value: Any?, key: String, index: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            throw usage("item \(index + 1) has a \(key) that is not a string")
        }
        return text.trimmedOrNil
    }

    /// Absent means not done. An agent writing a fresh list should not have to say so four times.
    ///
    /// The CFBoolean check is not pedantry: JSONSerialization hands back an `NSNumber` for both
    /// `true` and `1`, and Swift bridges either to `Bool` happily — so `"done": 7` would silently
    /// mean done. A number there is a mistake, and it is better said than absorbed.
    private static func optionalBool(_ value: Any?, index: Int) throws -> Bool {
        guard let value, !(value is NSNull) else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw usage("item \(index + 1) has a done that is not true or false")
        }
        return number.boolValue
    }

    private static func usage(_ problem: String) -> InputError {
        InputError.invalid("""
            Cannot read the actions: \(problem). Expected \
            [{"text": "…", "owner": "…", "due": "…", "done": false}]. text is required, the rest \
            are optional.
            """)
    }
}

// MARK: - transcript edit --add-vocab

/// What `--add-vocab` should actually add.
///
/// The promotion is offered only "if the edit changes a single word or short phrase", and that
/// condition is the whole guard: an edit that rewrites a sentence has no term in it, and adding the
/// rewritten sentence to the recogniser's vocabulary would be worse than adding nothing.
public enum Correction {
    public static let maximumTermWords = 3

    /// The run of words the correction introduced, found by trimming the words the two versions
    /// share at each end. `Torch zero pipeline` → `Torch0 pipeline` leaves `Torch0`.
    public static func term(from old: String, to new: String) throws -> String {
        let before = words(old), after = words(new)

        var head = 0
        while head < before.count, head < after.count, before[head].caseInsensitiveCompare(after[head]) == .orderedSame {
            head += 1
        }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              before[before.count - 1 - tail].caseInsensitiveCompare(after[after.count - 1 - tail]) == .orderedSame {
            tail += 1
        }

        let changed = Array(after[head..<(after.count - tail)])
        guard !changed.isEmpty else {
            throw InputError.invalid(
                "--add-vocab has nothing to add: that edit did not change any words. Drop the flag, "
                    + "or add the term directly with meetings vocab add <term>."
            )
        }
        guard changed.count <= maximumTermWords else {
            throw InputError.invalid("""
                --add-vocab needs the edit to change a word or a short phrase, and this one changed \
                \(changed.count) words. The edit itself is fine. Run it without --add-vocab, then \
                add the term you meant with meetings vocab add <term>.
                """)
        }
        return changed.joined(separator: " ")
    }

    /// Words with their surrounding punctuation trimmed. A term is going into a recogniser's
    /// vocabulary, and "ptychography." with the full stop attached would never match anything.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap {
            String($0).trimmingCharacters(in: punctuation).trimmedOrNil
        }
    }

    private static let punctuation = CharacterSet(charactersIn: ".,;:!?\"()[]{}—–…\u{2018}\u{2019}\u{201C}\u{201D}")
}
