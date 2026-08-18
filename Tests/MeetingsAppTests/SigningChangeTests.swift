import Foundation
import Testing

@testable import MeetingsApp

/// **The one launch that has to explain itself, and every launch that must not.**
///
/// macOS keys a TCC grant to the app's code signature, so the release that moves Meetings from a build
/// compiled on the user's own Mac to one prebuilt and signed by a shared certificate silently revokes
/// the microphone and Screen & System Audio Recording. The notice exists to say so before the prompts
/// arrive looking like a bug.
///
/// Every case here fails in a different direction, which is why there are this many of them. Miss the
/// change and somebody is asked for the microphone by an app that has had it for months, with no
/// explanation anywhere. Raise it on a first launch and the app opens with an apology for revoking
/// permissions it was never granted, talking over the setup wizard. Raise it on a from-source rebuild
/// and it is simply a false statement: that user signed with their own certificate and lost nothing.
///
/// The defaults suite is a throwaway domain: the real one holds the operator's own window state and
/// wizard progress, and `swift test` has no business writing to it.
@Suite final class SigningChangeTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "meetings-signing-test-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    /// The certificate minted on one user's Mac, and the shared distribution one. Real-shaped SHA-1
    /// hex, because that is what `CodeSignature.signingIdentity` produces and a comparison against a
    /// short token would pass with a truncating bug in it.
    private static let theirOwn = "3ba1a63ac6b6b2e0dd4be7cf30fa2b4d24f2d0aa"
    private static let distribution = "f5568c5d976fef4de1f44da76d6df5498a4fe882"

    /// A launch, spelled as the two facts the app knows about itself at the time. `usedBefore: false`
    /// by default because that is what a seeding first launch is, and seeding with prior use would
    /// trip the migration rule before the case under test got started.
    private func launch(
        _ identity: String?,
        usedBefore: Bool = false,
        isPrebuilt: Bool = true
    ) -> Bool {
        SigningChange.recordAndDetect(
            identity: identity, usedBefore: usedBefore, isPrebuilt: isPrebuilt, defaults: defaults
        )
    }

    // MARK: - The four launches that decide this

    /// A fresh install of a downloaded copy. Nothing was reset, and the wizard is about to ask for
    /// these permissions properly.
    @Test func aFirstEverLaunchOfADownloadedCopySaysNothing() {
        #expect(!launch(Self.distribution, usedBefore: false, isPrebuilt: true))
        // Recorded anyway, or the *second* launch would look like the migration.
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.distribution)
    }

    /// **The migration.** A long-standing user updates into the first prebuilt release: no build they
    /// have ever run recorded an identity, so there is nothing to compare — and their grants are
    /// definitely gone, because the shared distribution certificate is not the one their own Mac
    /// minted. Comparison alone answers "no change" here, which is the answer that loses the whole
    /// point of the notice.
    @Test func aMigratingUserOnADownloadedCopyIsExplainedTo() {
        #expect(launch(Self.distribution, usedBefore: true, isPrebuilt: true))
    }

    /// The same shape of launch — prior use, nothing recorded — on a copy the user compiled from their
    /// own checkout with `--from-source`. They signed it with the certificate they have always used,
    /// so nothing was revoked and there is nothing to explain.
    @Test func aRebuildFromSourceWithNothingRecordedSaysNothing() {
        #expect(!launch(Self.theirOwn, usedBefore: true, isPrebuilt: false))
        // And it still records, so if that user later downloads a release the change is caught by the
        // comparison rather than needing the migration rule again.
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true, isPrebuilt: true))
    }

    /// A later rotation of the distribution certificate, which resets the grants for everybody however
    /// their copy was built — so this one does not care whether the build was downloaded.
    @Test func aRotatedCertificateIsExplainedOnEveryKindOfBuild() {
        #expect(!launch(Self.distribution))
        #expect(launch(Self.theirOwn, usedBefore: true, isPrebuilt: false))
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
    }

    // MARK: - Everything that must stay quiet, and the flag that carries the notice

    @Test func theSameIdentityTwiceSaysNothing() {
        _ = launch(Self.theirOwn)
        #expect(!launch(Self.theirOwn, usedBefore: true))
    }

    /// Quitting is not dismissing. The permission prompts land at the next recording, which can be
    /// days after the launch that reset them, so the explanation has to still be there — the
    /// comparison alone answers no by then, because the new identity is already recorded.
    @Test func theNoticeSurvivesARelaunchAndOnlyDismissalEndsIt() {
        _ = launch(Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true))
        #expect(
            launch(Self.distribution, usedBefore: true),
            "relaunching before dismissing the notice loses the only explanation of the reset"
        )

        SigningChange.dismissNotice(defaults: defaults)
        #expect(!launch(Self.distribution, usedBefore: true))
    }

    /// An unreadable signature — an ad-hoc build, or a `swift run` with no bundle around it — is no
    /// evidence either way. Recording nothing over the last real identity would make the next signed
    /// launch look like a first launch, and a first launch is the case that says nothing at all.
    @Test func anUnreadableSignatureNeitherSpeaksNorForgets() {
        _ = launch(Self.theirOwn)

        #expect(!launch(nil, usedBefore: true))
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true))
    }

    /// And an already-owed notice is still owed after such a launch, since it is a flag rather than a
    /// comparison.
    @Test func anUnreadableSignatureKeepsAnOwedNotice() {
        _ = launch(Self.theirOwn)
        _ = launch(Self.distribution, usedBefore: true)
        #expect(launch(nil, usedBefore: true))
    }

    /// The button the notice offers has to open the Screen Recording pane specifically: that grant is
    /// a toggle the user must find, and every other pane in Privacy & Security is a wrong turn.
    @Test func theNoticePointsAtTheScreenRecordingPane() throws {
        let url = try #require(SigningChange.screenRecordingSettings)
        #expect(url.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
