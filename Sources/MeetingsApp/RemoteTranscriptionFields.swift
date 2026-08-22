import MeetingsCore
import SwiftUI

/// The four things a remote transcription endpoint needs, the button that proves they work, and the
/// sentence about where the audio goes.
///
/// One view for both places it appears — the setup wizard's transcriber step and Settings ›
/// Transcription — because the wizard verifying credentials that Settings then lets you break
/// unverified is the same feature with a hole in it.
struct RemoteTranscriptionFields: View {
    let store: MeetingStore
    /// A counter the wizard bumps to run the verification from its own Continue button. Ignored in
    /// Settings, which has only the button below.
    var verifyRequested: Int = 0
    /// A counter the caller bumps to mean "the settings rows changed underneath you — read them
    /// again".
    ///
    /// The fields below load into `@State` once, on appear, which is right for a pane the user is
    /// typing into: re-reading the store on every redraw would fight the cursor. It is wrong the
    /// moment something else writes those rows, and something else now does —
    /// ``MeetingStore/adoptCloudCredentialsForTranscription(keychainRead:keychainWrite:)`` copies the
    /// write-up provider's endpoint across when the user picks the service card. Without this the
    /// carry-over wrote four correct rows and left four visibly empty boxes sitting on top of them,
    /// which does not read as "nothing needed doing", it reads as the feature being broken.
    var reloadRequested: Int = 0
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
            Text("Audio is uploaded. Notes stay on this Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Color(nsColor: .systemBlue))
        }

        TextField("Base URL", text: SettingBinding(store: store, key: .transcribeRemoteBaseURL).binding($baseURL))
            .onAppear(perform: load)
        EgressWarning(key: .transcribeRemoteBaseURL, value: baseURL)
        TextField("Model", text: SettingBinding(store: store, key: .transcribeRemoteModel).binding($model))
        // Same disclosure and the same reason as the write-up provider's: the account is a label
        // with no correct value, and it does not belong between two fields that have one.
        DisclosureGroup("Keychain account (optional)") {
            TextField(
                "Keychain account",
                text: SettingBinding(store: store, key: .transcribeRemoteKeyRef).binding($keyRef)
            )
            .labelsHidden()
        }
        SecureField("API key", text: $key)
            .onSubmit(check)

        HStack(spacing: 10) {
            Button("Verify the service", action: check)
                .disabled(checking)
            if checking { ProgressView().controlSize(.small) }
        }
        .onChange(of: verifyRequested) { _, _ in check() }
        .onChange(of: reloadRequested) { _, _ in load() }

        if let result {
            VerifyResultLabel(result: result)
        }
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
