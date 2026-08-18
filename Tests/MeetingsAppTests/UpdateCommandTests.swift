import Foundation
import Testing

@testable import MeetingsApp

/// **The line the update notice hands somebody, for a copy that was downloaded rather than built.**
///
/// `AppInfo.updateCommand` has two answers and, until the app started shipping prebuilt, only the
/// source-checkout one was ever seen: the fallback ran when the bundle had no `MeetingsSourceRoot`,
/// which in practice meant a `swift run` during development. A downloaded release carries no source
/// root either, so the fallback is now what every user is shown, and a broken one leaves the notice
/// offering a command that does nothing.
///
/// The branch is a parameter rather than the bundle's own Info.plist because the test process runs
/// inside `swift test`'s bundle, whose keys no test can change — which is exactly why this half went
/// uncovered.
@Suite final class UpdateCommandTests {
    /// A directory with an apostrophe in its name, made for real so the quoting can be tested by
    /// running it rather than by re-deriving the escaping in the assertion.
    private let awkward: URL

    init() throws {
        awkward = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Sean's meetings \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: awkward, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: awkward) }

    @Test func aDownloadedCopyIsToldToRunTheInstaller() {
        let command = AppInfo.updateCommand(sourceRoot: nil)
        #expect(command == "curl -fsSL https://raw.githubusercontent.com/"
            + "yoelgal/meetings/main/install.sh | bash")
        // Named separately because the failure that matters is not a changed URL, it is this branch
        // handing out the source-build recipe to somebody who has no checkout to pull.
        #expect(!command.contains("git pull"), "a downloaded copy has nothing to pull: \(command)")
    }

    @Test func aBuildFromACheckoutIsToldWhereToPull() {
        #expect(AppInfo.updateCommand(sourceRoot: "/Users/someone/Developer/meetings")
            == "cd '/Users/someone/Developer/meetings' && git pull && ./install.sh")
    }

    /// **The sentence printed above that command.** The update notice has one branch with a button and
    /// one with a command, and the command branch is where every downloaded copy lands — it carries no
    /// `MeetingsSourceRoot`, so it can never self-update. It used to tell that copy "Meetings is built
    /// from source. Run this where you keep the repository", which is a false statement about how it
    /// got there and points at a repository the user does not have.
    @Test func aDownloadedCopyIsNeverToldItWasBuiltFromSource() {
        let text = SelfUpdate.howToUpdate(sourceRoot: nil)
        #expect(!text.lowercased().contains("built from"), "\(text)")
        #expect(!text.lowercased().contains("repository"),
                "a downloaded copy has no checkout to be sent to: \(text)")
        // And it says what this copy actually is, or "does not lie" would be satisfied by saying
        // nothing at all.
        #expect(text.contains("downloaded"))
    }

    /// The other copy in that branch: built from a checkout that has since moved or been deleted, so
    /// the command it is handed still names the old path and the only useful thing to say is where to
    /// run it instead.
    @Test func aStrandedCheckoutIsToldWhereToRunIt() {
        let text = SelfUpdate.howToUpdate(sourceRoot: "/Users/someone/Developer/meetings")
        #expect(text.contains("no longer where"))
        #expect(text.contains("repository"))
        #expect(!text.contains("downloaded"), "this copy was compiled, not fetched: \(text)")
    }

    /// The escaping, proved by handing the command to the shell that would run it.
    ///
    /// A single quote inside the single-quoted path ends the quoting, and the rest of the path becomes
    /// separate arguments — so `cd` succeeds *somewhere else* and the pull happens in whatever
    /// directory that turned out to be. Asserting the `'\''` spelling instead would only restate the
    /// implementation; running it is what shows the shell agrees.
    @Test func anApostropheInThePathStillCdsThere() throws {
        let command = AppInfo.updateCommand(sourceRoot: awkward.path)
        let cd = try #require(command.components(separatedBy: " && git pull").first)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(cd) && pwd"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "the shell could not run: \(cd)")
        // Resolved on both sides: the temporary directory lives under the /var symlink and `pwd`
        // prints the /private/var it resolves to.
        #expect(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
                == awkward.resolvingSymlinksInPath().path,
            "the command landed in \(printed) rather than \(awkward.path)"
        )
    }
}
