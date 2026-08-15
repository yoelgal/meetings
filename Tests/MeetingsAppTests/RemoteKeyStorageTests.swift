import Foundation
import MeetingsCore
import Testing

@testable import MeetingsApp

/// **Where the remote transcription API key ends up.** The settings table is a plain SQLite table
/// that `meetings config get` prints on request and that every backup copies verbatim; the key goes
/// to the login Keychain and the row holds only the account name it is filed under.
///
/// This used to be pinned by reading `RemoteTranscriptionFields.swift` as text and looking for
/// `setSetting(` and `, key)` on the same physical line. That is a formatting rule, not a security
/// one: the same mistake spelled `setSetting(.transcribeRemoteKeyRef, self.key)`, wrapped across two
/// lines, or passed through `key.trimmingCharacters(in: .whitespaces)` walks past it untouched. So
/// the save path runs for real here and the store is asked afterwards, which no amount of
/// reformatting can dodge.
///
/// **The Keychain write is injected, not performed.** A test that ran the real one would put the
/// operator's login Keychain in the blast radius of `swift test`.
@Suite final class RemoteKeyStorageTests {
    private let directory: URL
    private let store: MeetingStore

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-key-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MeetingStore(
            dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db"))
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A string no other value in the store could contain by accident, so "is the key in there" is
    /// answerable by looking rather than by knowing which row to look in. Deliberately not shaped
    /// like a real credential — a fixture that looks like one trips every secret scanner it passes.
    private static let typedKey = "the-user-typed-this-and-it-must-not-be-in-the-store"

    @Test func theTypedKeyIsInNoSettingsRowUnderAnyKey() throws {
        var written: (secret: String, account: String)?
        let account = RemoteTranscriptionFields.save(
            key: Self.typedKey, under: "", in: store, keychain: { written = ($0, $1) }
        )

        // It did go to the Keychain, under a name picked for the user — otherwise "not in the
        // settings table" would also be satisfied by the key being silently dropped.
        #expect(written?.secret == Self.typedKey)
        #expect(written?.account == account)
        #expect(account == RemoteTranscriptionFields.defaultKeyRef)

        let settings = try store.storedSettings()
        #expect(!settings.isEmpty, "the account name has to have been recorded, or nothing was saved")
        for (key, value) in settings {
            #expect(value != Self.typedKey, "the API key is in the settings table under \(key)")
            #expect(!value.contains(Self.typedKey), "the API key is embedded in the setting \(key)")
        }
        // And the row that exists is the account name, which is not a secret.
        #expect(try store.setting(.transcribeRemoteKeyRef) == RemoteTranscriptionFields.defaultKeyRef)
    }

    /// The same with an account name the user chose, which is the branch that skips the write of a
    /// default and so takes a different path to the same promise.
    @Test func aChosenAccountNameStillKeepsTheKeyOutOfTheStore() throws {
        try store.setSetting(.transcribeRemoteKeyRef, "work-openai")
        var written: (secret: String, account: String)?
        let account = RemoteTranscriptionFields.save(
            key: Self.typedKey, under: "work-openai", in: store, keychain: { written = ($0, $1) }
        )

        #expect(account == "work-openai")
        #expect(written?.account == "work-openai")
        for (key, value) in try store.storedSettings() {
            #expect(!value.contains(Self.typedKey), "the API key is in the settings table under \(key)")
        }
    }

    /// An empty field writes nothing at all. Without this, opening Settings and pressing Verify
    /// would delete a working key: `setSecret(nil)` removes the item, and an empty string is what
    /// the field holds every time the pane is opened.
    @Test func anEmptyFieldWritesNoSecretAndPicksNoAccount() throws {
        var written = false
        let account = RemoteTranscriptionFields.save(
            key: "", under: "", in: store, keychain: { _, _ in written = true }
        )
        #expect(!written, "an empty field must not reach the Keychain — that write is a delete")
        #expect(account.isEmpty)
        #expect(try store.storedSettings().isEmpty, "and it must not invent an account name either")
    }
}
