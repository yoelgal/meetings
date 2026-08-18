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
    ) -> SigningChange.Cause? {
        SigningChange.recordAndDetect(
            identity: identity, usedBefore: usedBefore, isPrebuilt: isPrebuilt, defaults: defaults
        )
    }

    // MARK: - The four launches that decide this

    /// A fresh install of a downloaded copy. Nothing was reset, and the wizard is about to ask for
    /// these permissions properly.
    @Test func aFirstEverLaunchOfADownloadedCopySaysNothing() {
        #expect(launch(Self.distribution, usedBefore: false, isPrebuilt: true) == nil)
        // Recorded anyway, or the *second* launch would look like the migration.
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.distribution)
    }

    /// **The migration.** A long-standing user updates into the first prebuilt release: no build they
    /// have ever run recorded an identity, so there is nothing to compare — and their grants are
    /// definitely gone, because the shared distribution certificate is not the one their own Mac
    /// minted. Comparison alone answers "no change" here, which is the answer that loses the whole
    /// point of the notice.
    ///
    /// An ad-hoc previous copy lands here too, and correctly: an ad-hoc signature has no certificate,
    /// so nothing was ever recorded for it either.
    @Test func aMigratingUserOnADownloadedCopyIsToldItIsTheMigration() {
        #expect(launch(Self.distribution, usedBefore: true, isPrebuilt: true) == .migration)
    }

    /// The same shape of launch — prior use, nothing recorded — on a copy the user compiled from their
    /// own checkout with `--from-source`. They signed it with the certificate they have always used,
    /// so nothing was revoked and there is nothing to explain.
    @Test func aRebuildFromSourceWithNothingRecordedSaysNothing() {
        #expect(launch(Self.theirOwn, usedBefore: true, isPrebuilt: false) == nil)
        // And it still records, so if that user later downloads a release the change is caught by the
        // comparison rather than needing the migration rule again.
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true, isPrebuilt: true) == .rotation)
    }

    /// **The case the migration's wording must not swallow.** Once the migration has shipped, every
    /// user's recorded identity is the distribution certificate, so a build signed by some other
    /// certificate arrives on this exact path — and macOS re-asking for permissions is the only signal
    /// the user gets that the signer was substituted. Reported as a rotation, and it does not care how
    /// the copy was built, because a rotation resets the grants either way.
    @Test func aDifferentCertificateIsReportedAsARotationOnEveryKindOfBuild() {
        #expect(launch(Self.distribution) == nil)
        #expect(launch(Self.theirOwn, usedBefore: true, isPrebuilt: false) == .rotation)
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
    }

    // MARK: - What each cause is allowed to say

    /// The migration is the routine one, so it says so: what changed, what will be asked for, and that
    /// it is the last time.
    @Test func theMigrationExplainsItselfAndPromisesItIsTheLastTime() {
        let text = SigningChange.Cause.migration.explanation
        #expect(text.contains("downloaded ready to run"))
        #expect(text.contains("Screen & System Audio Recording"))
        #expect(text.contains("Every update after this one keeps both"))
    }

    /// **A rotation must not be handed the migration's story.** The reassurance is true exactly once;
    /// repeated at a substituted signer it turns the one signal a user gets into a note saying not to
    /// worry. Behavioural rather than a scan of the source for the phrase: the phrase is *correct* on
    /// the migration and only wrong when it is unconditional, which a substring search over the file
    /// cannot tell apart. Asking each cause is what can.
    @Test func aRotationIsNeverExplainedAwayAsTheRoutineReset() {
        let text = SigningChange.Cause.rotation.explanation
        #expect(!text.contains("Every update after this one keeps both"), """
            a substituted signer is told the reset was routine and will not recur: "\(text)"
            """)
        #expect(!text.contains("one more time"), "nor that this is the single expected re-ask")
        #expect(!text.contains("downloaded ready to run"),
                "and it must not claim to know where this build came from")
        // It has to be actionable, or "says nothing reassuring" would be satisfied by saying nothing.
        #expect(text.contains("different certificate"))
        #expect(text.contains("where it came from"))
    }

    /// Neither cause may fall through to the other's headline, and a third case added later cannot
    /// ship blank.
    @Test func everyCauseSaysSomethingOfItsOwn() {
        for cause in SigningChange.Cause.allCases {
            #expect(!cause.title.isEmpty, "\(cause) has no row title")
            #expect(!cause.detail.isEmpty, "\(cause) has no row detail")
            #expect(!cause.headline.isEmpty, "\(cause) has no headline")
            #expect(!cause.symbol.isEmpty, "\(cause) has no symbol")
        }
        #expect(SigningChange.Cause.migration.headline != SigningChange.Cause.rotation.headline)
        #expect(SigningChange.Cause.migration.title != SigningChange.Cause.rotation.title)
        #expect(SigningChange.Cause.migration.explanation != SigningChange.Cause.rotation.explanation)
    }

    // MARK: - Everything that must stay quiet, and the record that carries the notice

    @Test func theSameIdentityTwiceSaysNothing() {
        _ = launch(Self.theirOwn)
        #expect(launch(Self.theirOwn, usedBefore: true) == nil)
    }

    /// Quitting is not dismissing. The permission prompts land at the next recording, which can be
    /// days after the launch that reset them, so the explanation has to still be there — and still be
    /// the *same* explanation, since the comparison answers "no change" by then.
    @Test func theNoticeSurvivesARelaunchAndOnlyDismissalEndsIt() {
        _ = launch(Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true) == .rotation)
        #expect(
            launch(Self.distribution, usedBefore: true) == .rotation,
            "relaunching before dismissing the notice loses the only explanation of the reset"
        )

        SigningChange.dismissNotice(defaults: defaults)
        #expect(launch(Self.distribution, usedBefore: true) == nil)
    }

    /// An unreadable signature — an ad-hoc build, or a `swift run` with no bundle around it — is no
    /// evidence either way. Recording nothing over the last real identity would make the next signed
    /// launch look like a first launch, and a first launch is the case that says nothing at all.
    @Test func anUnreadableSignatureNeitherSpeaksNorForgets() {
        _ = launch(Self.theirOwn)

        #expect(launch(nil, usedBefore: true) == nil)
        #expect(defaults.string(forKey: SigningChange.identityKey) == Self.theirOwn)
        #expect(launch(Self.distribution, usedBefore: true) == .rotation)
    }

    /// And an already-owed notice is still owed after such a launch, with its cause intact, since it is
    /// a stored answer rather than a comparison.
    @Test func anUnreadableSignatureKeepsAnOwedNotice() {
        _ = launch(Self.theirOwn)
        _ = launch(Self.distribution, usedBefore: true)
        #expect(launch(nil, usedBefore: true) == .rotation)
    }

    /// The button the notice offers has to open the Screen Recording pane specifically: that grant is
    /// a toggle the user must find, and every other pane in Privacy & Security is a wrong turn.
    @Test func theNoticePointsAtTheScreenRecordingPane() throws {
        let url = try #require(SigningChange.screenRecordingSettings)
        #expect(url.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
