import Foundation

extension MeetingStore {
    /// Copies `ai.cloud.baseURL` / `.model` / the Keychain secret onto the `transcribe.remote.*`
    /// rows, so somebody who has already configured a cloud write-up provider does not type the same
    /// three values again to transcribe there too. Returns true when anything was copied.
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
    /// ## The endpoint and its key travel together, or neither travels
    ///
    /// This used to copy each field independently, each guarded only on its own destination row being
    /// empty, and that leaked API keys to third parties. `RemoteTranscriptionFields.load()` writes
    /// `https://api.openai.com/v1` onto the transcription row the first time that pane is *looked at*
    /// and never writes a `keyRef`, so "endpoint filled, key empty" is the ordinary state of any
    /// install that has glanced at cloud transcription. Adoption then found the endpoint occupied,
    /// skipped it, found the key empty, and filled it — from a *different* provider. The result was
    /// `Authorization: Bearer <Anthropic key>` sent to `api.openai.com` along with the audio of every
    /// meeting, under a green tick claiming the fields had been filled in helpfully. Pressing
    /// "Verify the service" was enough to transmit it; no meeting was required.
    ///
    /// So the unit of adoption is the whole triple, not three fields. When transcription already
    /// points somewhere other than the write-up provider, **nothing** is copied: that endpoint was
    /// chosen — by the user or by the pane's own default — and a key belonging to another provider has
    /// no business being paired with it. What remains is the case the convenience was for: a
    /// transcription endpoint that is unset, or already the same endpoint the key belongs to.
    ///
    /// Only-where-empty still guards each individual row inside that check, which is what makes this
    /// safe to call whenever the cloud fields change — it can run twice and still cannot take a value
    /// away from anybody.
    ///
    /// The Keychain is injectable for exactly one reason: `swift test` must never touch the
    /// operator's login Keychain. The repo already does this in `RemoteTranscriptionFields.save`.
    @discardableResult
    public func adoptCloudCredentialsForTranscription(
        keychainRead: (String) -> String? = { MeetingsKeychain.secret(account: $0) },
        keychainWrite: (String?, String) -> Void = { MeetingsKeychain.setSecret($0, account: $1) }
    ) throws -> Bool {
        // Nothing to adopt without a source endpoint. A model or a key on its own names no provider,
        // and copying either would be filling a form with values whose destination is unknown.
        guard let sourceURL = filled(try setting(.aiCloudBaseURL)) else { return false }

        // The consistency gate. Equality is on the trimmed string rather than a parsed URL: this is
        // asking "did these two fields come from the same place", and two spellings of one host are
        // not evidence of that.
        let destinationURL = filled(try setting(.transcribeRemoteBaseURL))
        guard destinationURL == nil || same(destinationURL, sourceURL) else { return false }

        // The same write gate `SettingBinding` and `meetings config set` apply, because this is the
        // third writer of an egress row and a rule one of three doors enforces is not a rule. The
        // population it protects is real: a non-loopback `http://` in `ai.cloud.baseURL` predates the
        // refusal, and promoting it here would put every meeting's audio on the wire in the clear
        // through a door that never asked.
        guard SettingKey.egressRefusal(sourceURL, for: .transcribeRemoteBaseURL) == nil else {
            return false
        }

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
        //
        // The destination *item* is checked, not just the destination row. `MeetingsKeychain
        // .setSecret` is a delete-then-add upsert, and the row can be empty while the item is not —
        // clearing the Keychain-account field in Settings stores nil on the row and leaves the secret
        // behind. Guarding on the row alone therefore destroyed a live key that was still in use.
        if let source = filled(try setting(.aiCloudKeyRef)),
           filled(try setting(.transcribeRemoteKeyRef)) == nil,
           filled(keychainRead("transcribe")) == nil,
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

/// Whether two stored endpoints are the same one, ignoring only the whitespace a text field leaves.
private func same(_ lhs: String?, _ rhs: String) -> Bool {
    guard let lhs else { return false }
    let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
    return trim(lhs) == trim(rhs)
}
