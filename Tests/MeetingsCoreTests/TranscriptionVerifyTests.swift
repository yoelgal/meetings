import Foundation
import Testing

@testable import MeetingsCore

/// The check that stands between a mistyped API key and a meeting recorded with no transcript.
///
/// Driven through the transport closure rather than a socket, so every branch — including the ones a
/// real provider only produces when you get it wrong — is exercised without an account.
@Suite struct TranscriptionVerifyTests {
    static func transport(
        status: Int, body: String = "{}",
        capture: (@Sendable (URLRequest) -> Void)? = nil
    ) -> HTTPTransport {
        { request in
            capture?(request)
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    @Test func aWorkingEndpointPassesAndSaysTheAudioIsUploaded() async {
        let result = await TranscriptionVerify.remote(
            baseURL: "https://api.openai.com/v1", model: "whisper-1", keyRef: "transcribe",
            key: "sk-good", transport: Self.transport(status: 200, body: #"{"text":""}"#))

        #expect(result.ok)
        #expect(result.message.contains("whisper-1"))
        #expect(result.message.contains("uploaded"),
                "a pass is the moment to restate where the audio goes")
    }

    /// The request has to be the one the engine sends, or the check proves nothing about the engine.
    @Test func theProbeGoesToTheTranscriptionsEndpointWithTheKeyAndTheModel() async {
        let seen = RequestBox()
        _ = await TranscriptionVerify.remote(
            baseURL: "https://example.test/v1", model: "whisper-large", keyRef: "k", key: "sk-abc",
            transport: Self.transport(status: 200, body: #"{"text":""}"#) { seen.store($0) })

        let request = seen.value
        #expect(request?.url?.path == "/v1/audio/transcriptions")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abc")
        let body = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("whisper-large"))
        #expect(body.contains("RIFF"), "the probe has to carry a real WAV, not an empty part")
    }

    @Test func aRejectedKeySaysSoAndNeverQuotesTheKeyBack() async {
        // OpenAI's 401 body echoes the key it rejected; relaying it verbatim is how a key ends up
        // in a screenshot.
        let body = #"{"error":{"message":"Incorrect API key provided: sk-secret-value-here."}}"#
        let result = await TranscriptionVerify.remote(
            baseURL: "https://api.openai.com/v1", model: "whisper-1", keyRef: "k",
            key: "sk-secret-value-here", transport: Self.transport(status: 401, body: body))

        #expect(result.ok == false)
        #expect(result.message.contains("rejected the API key"))
        #expect(!result.message.contains("sk-secret-value-here"))
    }

    @Test func anUnknownModelIsReportedInTheProvidersOwnWords() async {
        let body = #"{"error":{"message":"The model `whisper-9` does not exist"}}"#
        let result = await TranscriptionVerify.remote(
            baseURL: "https://api.openai.com/v1", model: "whisper-9", keyRef: "k", key: "sk-good",
            transport: Self.transport(status: 400, body: body))

        #expect(result.ok == false)
        #expect(result.message.contains("whisper-9"))
    }

    @Test func anUnreachableEndpointIsReportedAsUnreachableRatherThanRejected() async {
        let result = await TranscriptionVerify.remote(
            baseURL: "https://nowhere.invalid/v1", model: "whisper-1", keyRef: "k", key: "sk-good",
            transport: { _ in throw URLError(.cannotFindHost) })

        #expect(result.ok == false)
        #expect(result.message.contains("Could not reach nowhere.invalid"))
    }

    /// Each missing piece names itself, because "verification failed" with four empty fields tells
    /// the user nothing about which one to fill in.
    @Test func eachMissingPieceIsNamedAndNothingIsSent() async {
        let sent = RequestBox()
        let never = Self.transport(status: 200) { sent.store($0) }

        let noURL = await TranscriptionVerify.remote(
            baseURL: nil, model: "m", keyRef: "k", key: "s", transport: never)
        let noModel = await TranscriptionVerify.remote(
            baseURL: "https://x.test", model: "", keyRef: "k", key: "s", transport: never)
        let noRef = await TranscriptionVerify.remote(
            baseURL: "https://x.test", model: "m", keyRef: "", key: "s", transport: never)
        let noKey = await TranscriptionVerify.remote(
            baseURL: "https://x.test", model: "m", keyRef: "openai", key: nil, transport: never)

        #expect(noURL.message.contains("base URL"))
        #expect(noModel.message.contains("model"))
        #expect(noRef.message.contains("Keychain account"))
        #expect(noKey.message.contains("openai"), "the account it looked under is the useful half")
        for result in [noURL, noModel, noRef, noKey] { #expect(result.ok == false) }
        #expect(sent.value == nil, "an incomplete configuration must not reach the network")
    }

    /// The probe is a real WAV: a provider that parses the header has to accept it, and a run has to
    /// produce the same bytes every time so a failure is about the endpoint.
    @Test func theSilentProbeIsAValidWAVOfTheRequestedLength() {
        let wav = TranscriptionVerify.silentWAV(seconds: 0.5)
        #expect(wav.count == 44 + 8_000 * 2)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav == TranscriptionVerify.silentWAV(seconds: 0.5))
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var value: URLRequest? { lock.withLock { stored } }
    func store(_ request: URLRequest) { lock.withLock { stored = request } }
}
