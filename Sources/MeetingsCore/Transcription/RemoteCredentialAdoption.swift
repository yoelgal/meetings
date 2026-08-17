import Foundation

extension MeetingStore {
    /// Copies `ai.cloud.baseURL` / `.model` / the Keychain secret onto the `transcribe.remote.*`
    /// rows, but only where the transcription row is still empty — a value the user typed is never
    /// overwritten. Returns true when anything was copied.
    ///
    /// The two settings exist because they are genuinely two decisions: where a *write-up* is
    /// generated and where *audio* is uploaded are different sentences with different consequences,
    /// and merging them would mean somebody who pointed the write-up at a cloud provider had silently
    /// agreed to upload every recording too. But the same person, having typed a base URL, a model
    /// and an API key into one of them, should not have to type all three again into the other — and
    /// what happened instead was the second form sitting there empty, transcription reporting itself
    /// "selected but not fully configured", and nothing explaining that the credentials they had
    /// already entered were for the other feature.
    ///
    /// Only-where-empty is what makes it safe to call this whenever the cloud fields change: it can
    /// run twice, or after the user has deliberately pointed transcription somewhere else, and it
    /// still cannot take a value away from them.
    ///
    /// The Keychain is injectable for exactly one reason: `swift test` must never touch the
    /// operator's login Keychain. The repo already does this in `RemoteTranscriptionFields.save`.
    @discardableResult
    public func adoptCloudCredentialsForTranscription(
        keychainRead: (String) -> String? = { MeetingsKeychain.secret(account: $0) },
        keychainWrite: (String?, String) -> Void = { MeetingsKeychain.setSecret($0, account: $1) }
    ) throws -> Bool {
        var copied = false
        for (source, destination) in [
            (SettingKey.aiCloudBaseURL, SettingKey.transcribeRemoteBaseURL),
            (SettingKey.aiCloudModel, SettingKey.transcribeRemoteModel),
        ] {
            guard let value = filled(try setting(source)), filled(try setting(destination)) == nil
            else { continue }
            try setSetting(destination, value)
            copied = true
        }

        // The secret is copied, not the account name. Two rows pointing at one Keychain item would
        // mean deleting the write-up's key silently breaking transcription months later, and the
        // account name a key is filed under is not a value the user chose for a reason — it is a
        // label. `"transcribe"` is hardcoded rather than read from the app layer because Core cannot
        // see `RemoteTranscriptionFields.defaultKeyRef`, and it is the name the engine has always
        // read, so a key stored by an older build is still found.
        //
        // No secret to copy means no row is written at all: a `keyRef` pointing at an empty Keychain
        // account is worse than no `keyRef`, because it makes the configuration *look* complete and
        // then fails on the first upload.
        if let source = filled(try setting(.aiCloudKeyRef)),
           filled(try setting(.transcribeRemoteKeyRef)) == nil,
           let secret = filled(keychainRead(source)) {
            keychainWrite(secret, "transcribe")
            try setSetting(.transcribeRemoteKeyRef, "transcribe")
            copied = true
        }
        return copied
    }
}

/// A row that exists and holds nothing is the same as a row that does not exist. Both front ends can
/// leave an empty string behind — a field the user typed into and then cleared — and treating that as
/// "already set" is what would make adoption silently do nothing on exactly the install that needs
/// it.
private func filled(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return value
}
