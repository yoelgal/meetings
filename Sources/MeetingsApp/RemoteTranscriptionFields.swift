import MeetingsCore
import SwiftUI

/// The four things a remote transcription endpoint needs, the button that proves they work, and the
/// sentence about where the audio goes.
///
/// One view for both places it appears — the setup wizard's model step and Settings › Transcription
/// — because the wizard verifying credentials that Settings then lets you break unverified is the
/// same feature with a hole in it.
struct RemoteTranscriptionFields: View {
    let store: MeetingStore
    /// A counter the wizard bumps to run the verification from its own Continue button. Ignored in
    /// Settings, which has only the button below.
    var verifyRequested: Int = 0
    /// Told whether the endpoint is currently proven, so the wizard can hold Continue.
    var verificationChanged: (AIVerification?) -> Void = { _ in }

    @State private var baseURL = ""
    @State private var model = ""
    @State private var keyRef = ""
    @State private var key = ""
    @State private var checking = false
    @State private var result: AIVerification?

    /// The account the key is filed under when the user has not picked one. Matches the name the
    /// engine has always read, so a key stored by an older build is still found.
    static let defaultKeyRef = "transcribe"

    var body: some View {
        Label {
            Text("The audio of every meeting is uploaded to this endpoint. Nothing else about "
                + "Meetings changes — notes, search and your write-up stay on this Mac — but the "
                + "recordings themselves leave it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Color(nsColor: .systemBlue))
        }

        TextField("Base URL", text: SettingBinding(store: store, key: .transcribeRemoteBaseURL).binding($baseURL))
            .onAppear(perform: load)
        TextField("Model", text: SettingBinding(store: store, key: .transcribeRemoteModel).binding($model))
        // Same disclosure and the same reason as the write-up provider's: the account is a label
        // with no correct value, and it does not belong between two fields that have one.
        DisclosureGroup("Keychain account") {
            TextField(
                "Keychain account",
                text: SettingBinding(store: store, key: .transcribeRemoteKeyRef).binding($keyRef)
            )
            .labelsHidden()
            Text("The name this key is filed under in your Keychain. Any name works. Left blank, "
                + "Meetings uses \"\(Self.defaultKeyRef)\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SecureField("API key", text: $key)
            .onSubmit(check)

        HStack(spacing: 10) {
            Button("Verify the endpoint", action: check)
                .disabled(checking)
            if checking { ProgressView().controlSize(.small) }
        }

        if let result {
            VerifyResultLabel(result: result)
        } else {
            // The default is to verify, and this says so before the user has pressed anything.
            // Skipping is offered — an endpoint behind a VPN that is not up yet is a real situation —
            // but it is the second thing on the line, not the first.
            Text("Verify before continuing. A key that is wrong here fails silently after your "
                + "first meeting, with the audio already recorded and no transcript to show for it. "
                + "If the endpoint is unreachable right now you can continue anyway and verify "
                + "later from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Defaults are OpenAI's, because the engine speaks OpenAI's "

            + "POST /audio/transcriptions — any endpoint that speaks it works, including one you "
            + "run yourself. The key goes to the login Keychain under service "
            + "com.yoelgal.Meetings; the settings table stores only the account name.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Zero is the initial value, so the first press is 1 and this never fires on appear.
            .onChange(of: verifyRequested) { _, _ in check() }
    }

    // MARK: -

    /// Defaults filled in on first sight rather than shipped as `SettingKey.defaults`: a store whose
    /// `transcribe.remote.baseURL` reads as OpenAI's by default would make
    /// `OpenAICompatibleRemoteEngine.Configuration.resolve` two thirds satisfied on every install
    /// that never chose the cloud at all, and that guard is what keeps the default install off the
    /// network.
    private func load() {
        baseURL = loadSetting(store, .transcribeRemoteBaseURL)
        model = loadSetting(store, .transcribeRemoteModel)
        keyRef = loadSetting(store, .transcribeRemoteKeyRef)
        if baseURL.isEmpty {
            baseURL = "https://api.openai.com/v1"
            try? store.setSetting(.transcribeRemoteBaseURL, baseURL)
        }
        if model.isEmpty {
            model = "whisper-1"
            try? store.setSetting(.transcribeRemoteModel, model)
        }
    }

    private func check() {
        // A key typed and not submitted is not in the Keychain yet, and a verification reporting
        // "no API key" with one plainly sitting in the field above it reads as the check being
        // broken rather than the key being unsaved.
        saveKey()
        result = nil
        verificationChanged(nil)
        checking = true
        Task {
            let outcome = await TranscriptionVerify.remote(store: store)
            checking = false
            result = outcome
            verificationChanged(outcome)
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        keyRef = Self.save(key: key, under: keyRef, in: store)
        key = ""
    }

    /// **The key never enters the settings table.** The row holds the Keychain *account name*; this
    /// writes the secret under it, picking a name when the user has not, and hands the name back so
    /// the field shows what was chosen.
    ///
    /// A function rather than four lines inside the view's `@State`, because "the secret is not in
    /// the store afterwards" is then a property of the store that a test can read. It was guarded by
    /// a substring scan of this file for a `setSetting(` call ending `, key)` on one physical line —
    /// which `setSetting(.transcribeRemoteKeyRef, self.key)`, a wrapped call, or a trimmed copy of
    /// the same variable all walk straight past. The guard, not the code, was the defect; see
    /// `RemoteKeyStorageTests`, which runs this and then asks the store.
    ///
    /// `keychain` is injectable for exactly one reason: a test that ran the real write would put the
    /// operator's login Keychain in the blast radius of `swift test`.
    static func save(
        key: String,
        under keyRef: String,
        in store: MeetingStore,
        keychain: (String, String) -> Void = { MeetingsKeychain.setSecret($0, account: $1) }
    ) -> String {
        guard !key.isEmpty else { return keyRef }
        var account = keyRef
        if account.isEmpty {
            account = defaultKeyRef
            try? store.setSetting(.transcribeRemoteKeyRef, account)
        }
        keychain(key, account)
        return account
    }
}
