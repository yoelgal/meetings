import ArgumentParser
import Foundation
import MeetingsCore

/// The three write-up modes, from the side an agent debugging somebody's setup is standing on.
struct AICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "The write-up mode, and whether it actually works.",
        subcommands: [AIVerifyCommand.self]
    )
}

struct AIVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check the configured write-up mode and say what was checked.",
        discussion: """
            manual checks nothing, because nothing runs.

            localAgent resolves the command template's binary against the PATH the app launches it \
            with. The command itself is never run: it would write a summary over a real meeting and \
            spend your agent subscription.

            cloud sends one one-token request to the endpoint you configured. Nothing is sent \
            anywhere else, and the API key is never printed, in either output shape.

            A mode that does not work is exit 3 with the same sentence.
            """
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let mode = AIMode(stored: try context.store.setting(.aiMode))
            let result = await AIVerify.mode(mode, store: context.store)
            // Thrown before anything is written, so a failure is one error envelope rather than a
            // success envelope followed by one — `--json` is exactly one JSON value either way.
            guard result.ok else { throw CLIError.invalidState(result.message) }
            if global.json {
                try Out.json(AIVerifyJSON(mode: mode.rawValue, ok: true, message: result.message))
                return
            }
            Out.line(result.message)
        }
    }
}

struct AIVerifyJSON: Encodable {
    let mode: String
    let ok: Bool
    /// What was checked, in one sentence. Never carries the API key.
    let message: String
}
