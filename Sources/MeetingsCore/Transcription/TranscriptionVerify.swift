import Foundation

/// Checks a remote transcription endpoint by actually calling it.
///
/// The failure this exists to prevent is specific: a wizard that accepts a mistyped key, completes,
/// and then fails silently after the user's first real meeting — by which point the audio is
/// recorded, the transcript is missing, and nothing on screen connects the two. One real request
/// during setup costs a fraction of a cent and moves that failure to the moment it can be fixed.
///
/// The request is built by ``OpenAICompatibleRemoteEngine`` itself, on half a second of silence, so
/// what comes back is about the configuration and not about a lookalike request. A provider that
/// rejects the key answers 401 whatever the audio is; one that does not know the model answers 400
/// or 404; one that is unreachable does not answer at all. All three are what the user needs to know
/// and none of them requires speech.
public enum TranscriptionVerify {
    public static func remote(
        baseURL: String?,
        model: String?,
        keyRef: String?,
        key: String?,
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> AIVerification {
        guard let baseURL, !baseURL.isEmpty, let url = URL(string: baseURL), url.scheme != nil else {
            return AIVerification(ok: false, message: "No base URL is set, so there is no endpoint to call.")
        }
        guard let model, !model.isEmpty else {
            return AIVerification(ok: false, message: "No model is set, so nothing was sent.")
        }
        guard let keyRef, !keyRef.isEmpty else {
            return AIVerification(ok: false, message: "No Keychain account is set, so there is no API key to send.")
        }
        guard let key, !key.isEmpty else {
            return AIVerification(
                ok: false,
                message: "No API key is in the Keychain under the account \(keyRef), so nothing was sent.")
        }

        let host = url.host() ?? url.absoluteString
        let boundary = "meetings.verify.\(UUID().uuidString)"
        var request = URLRequest(url: url.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = OpenAICompatibleRemoteEngine.multipartBody(
            boundary: boundary,
            fields: ["model": model, "response_format": "verbose_json"],
            fileField: "file",
            fileName: "probe.wav",
            fileData: silentWAV(seconds: 0.5)
        )

        do {
            let (body, response) = try await transport(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                // Scrubbed on the way out for the same reason ``AIVerify`` scrubs: OpenAI's 401 body
                // quotes the rejected key straight back, and this sentence is the one most likely to
                // end up in a screenshot.
                return AIVerification(
                    ok: false, message: AIVerify.redacting(key, in: sentence(host: host, code: code, body: body)))
            }
            // A 2xx from `/audio/transcriptions` is the whole answer: reachable, authenticated, and
            // the model accepted. The transcript of half a second of silence is empty by design and
            // is deliberately not inspected — treating an empty transcript as a failure would fail a
            // perfectly good endpoint.
            return AIVerification(
                ok: true,
                message: "\(host) accepted the model \(model) and transcribed a test clip. "
                    + "Audio from your meetings will be uploaded there.")
        } catch {
            return AIVerification(ok: false, message: "Could not reach \(host): \(AIVerify.sentence(for: error)).")
        }
    }

    /// The store's own settings, resolved and checked. The Keychain read happens here so the
    /// function above stays drivable from a test without the login Keychain.
    public static func remote(
        store: MeetingStore,
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> AIVerification {
        let keyRef = (try? store.setting(.transcribeRemoteKeyRef)) ?? nil
        return await remote(
            baseURL: (try? store.setting(.transcribeRemoteBaseURL)) ?? nil,
            model: (try? store.setting(.transcribeRemoteModel)) ?? nil,
            keyRef: keyRef,
            key: keyRef.flatMap { MeetingsKeychain.secret(account: $0) },
            transport: transport
        )
    }

    // MARK: -

    private static func sentence(host: String, code: Int, body: Data) -> String {
        let detail = providerMessage(body).map { ": \($0)" } ?? ""
        if code == 401 || code == 403 { return "\(host) rejected the API key\(detail)." }
        if code == 404 { return "\(host) has no /audio/transcriptions endpoint\(detail)." }
        return "\(host) returned HTTP \(code)\(detail)."
    }

    private struct ProviderError: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }

    private static func providerMessage(_ data: Data) -> String? {
        let raw = (try? JSONDecoder().decode(ProviderError.self, from: data))?.error.message
            ?? String(decoding: data.prefix(512), as: UTF8.self)
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        let capped = flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
        return capped.hasSuffix(".") ? String(capped.dropLast()) : capped
    }

    /// A valid 16 kHz mono 16-bit PCM WAV of silence, built by hand.
    ///
    /// Not synthesised with `say`: this has to work on a machine with no voices installed, and it has
    /// to be byte-identical every run so a failure is about the endpoint rather than about what the
    /// synthesiser happened to produce. Half a second because providers reject files shorter than
    /// about 0.1 s as empty.
    static func silentWAV(seconds: Double) -> Data {
        let rate = 16_000
        let frames = max(1, Int(seconds * Double(rate)))
        let dataBytes = frames * 2
        var wav = Data()
        func ascii(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { wav.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
        func u16(_ value: Int) { wav.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }

        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)          // PCM header length
        u16(1)           // format: PCM
        u16(1)           // channels
        u32(rate)
        u32(rate * 2)    // byte rate
        u16(2)           // block align
        u16(16)          // bits per sample
        ascii("data")
        u32(dataBytes)
        wav.append(Data(repeating: 0, count: dataBytes))
        return wav
    }
}
