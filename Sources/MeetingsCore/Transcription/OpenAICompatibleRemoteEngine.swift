import Foundation

/// The optional remote batch engine: any endpoint that speaks OpenAI's
/// `POST /audio/transcriptions`. Off unless every piece of configuration is present — base URL,
/// model, and an API key that resolves out of the Keychain — so the default install never reaches
/// the network and never has a key sitting in the settings table.
public struct OpenAICompatibleRemoteEngine: TranscriptionEngine {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let model: String
        /// Read from the Keychain at resolve time (``MeetingsKeychain``, the one accessor in the
        /// app). The settings row holds only the account name.
        public let apiKey: String

        public init(baseURL: URL, model: String, apiKey: String) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }

        /// Nil unless all three parts are configured. Deliberately the only way to build one: an
        /// engine that exists but is half-configured would fail mid-meeting instead of at setup.
        public static func resolve(baseURL: String?, model: String?, keyRef: String?) -> Configuration? {
            guard let baseURL, let url = URL(string: baseURL), url.scheme != nil,
                  let model, !model.isEmpty,
                  let keyRef, !keyRef.isEmpty,
                  let key = MeetingsKeychain.secret(account: keyRef), !key.isEmpty
            else { return nil }
            return Configuration(baseURL: url, model: model, apiKey: key)
        }
    }

    public let name = "remote"
    public var model: String { configuration.model }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Nothing to download. Reporting completion keeps onboarding's progress handling uniform.
    public func prepare(progress: @Sendable (Double) -> Void) async throws { progress(1) }

    /// A remote endpoint does its own thing with the terms, or nothing; either way there is nothing
    /// here to inspect.
    public func vocabularyReport() async -> VocabularyBiasingReport? { nil }

    public func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] {
        let data = try Data(contentsOf: audio)
        guard !data.isEmpty else { return [] }

        let boundary = "meetings.\(UUID().uuidString)"
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "model": configuration.model,
                // verbose_json is the only response format that carries segment timings, and without
                // timings a note cannot anchor to anything.
                "response_format": "verbose_json",
                // The API's own vocabulary hook. Terms only — no instructions, the app holds no prompts.
                "prompt": vocabulary.map(\.term).joined(separator: ", "),
            ].filter { !$0.value.isEmpty },
            fileField: "file",
            fileName: audio.lastPathComponent,
            fileData: data
        )

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.remoteFailed("no HTTP response from \(configuration.baseURL)")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Scrubbed for the same reason ``TranscriptionVerify`` scrubs, and it matters more
            // here: this text does not stop at a window. It is written into `transcript_issues`
            // by the batch pass, which puts it in the world-readable store and in the `issues.json`
            // of every bundle the user exports — and OpenAI's 401 body quotes the rejected key
            // straight back at you.
            let detail = AIVerify.redacting(
                configuration.apiKey, in: String(data: body.prefix(512), encoding: .utf8) ?? "")
            throw TranscriptionError.remoteFailed("HTTP \(http.statusCode) from \(configuration.baseURL): \(detail)")
        }

        let decoded: VerboseTranscription
        do {
            decoded = try JSONDecoder().decode(VerboseTranscription.self, from: body)
        } catch {
            throw TranscriptionError.remoteFailed("unreadable response: \(error)")
        }
        return decoded.engineSegments()
    }

    public func release() async {}

    // MARK: -

    struct VerboseTranscription: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        let text: String?
        let duration: Double?
        let segments: [Segment]?

        /// A server that ignores `verbose_json` still returns `text`; one whole-file segment beats
        /// dropping the transcript on the floor.
        func engineSegments() -> [EngineSegment] {
            if let segments, !segments.isEmpty {
                return segments.compactMap { segment in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return EngineSegment(
                        startMs: Int((segment.start * 1000).rounded()),
                        endMs: Int((segment.end * 1000).rounded()),
                        text: text
                    )
                }
            }
            let whole = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !whole.isEmpty else { return [] }
            return [EngineSegment(startMs: 0, endMs: Int(((duration ?? 0) * 1000).rounded()), text: whole)]
        }
    }

    static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
