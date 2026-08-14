import Foundation

/// Mode C: an OpenAI-compatible chat endpoint writes the summary, for a machine with no
/// agent installed. Off by default and behind "advanced" in Settings, because it sends the
/// transcript to a third party.
///
/// It is not the *only* mode that does — Mode B runs whatever command the user configured, and the
/// shipped default is `claude -p`, which sends the transcript to Anthropic. The UI used to say this
/// was the only mode that sent anything off the Mac, and that was false in the most damaging
/// direction: it read as a reassurance about Mode B.
///
/// Deliberately minimal: one request, one response, straight into `summary`. Anything cleverer —
/// retries, streaming, tool use — belongs in the user's own agent, which is what Modes A and B are.
public struct CloudEnhancer: Sendable {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let model: String
        public let apiKey: String

        /// Nil unless every piece is present. A half-configured provider that fails at the end of a
        /// meeting is worse than one that plainly says it is not set up.
        ///
        /// The chain itself lives in ``AIVerify/cloudSetup(baseURL:model:keyRef:key:)``, so what
        /// counts as configured and the sentence saying what is missing cannot drift apart.
        public static func resolve(baseURL: String?, model: String?, keyRef: String?) -> Configuration? {
            guard case .ready(let configuration) = AIVerify.cloudSetup(
                baseURL: baseURL,
                model: model,
                keyRef: keyRef,
                key: keyRef.flatMap { MeetingsKeychain.secret(account: $0) }
            ) else { return nil }
            return configuration
        }

        public init(baseURL: URL, model: String, apiKey: String) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    private let configuration: Configuration
    /// The same seam the verify button sends its probe over, so a test can drive a whole write-up —
    /// prompt, response, the write into `summary` — without a socket.
    private let transport: HTTPTransport

    public init(configuration: Configuration, transport: @escaping HTTPTransport = AIVerify.liveTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Writes the returned markdown into `summary` and moves the meeting to `complete`. Actions are
    /// left inside the markdown rather than parsed out: guessing structure from prose is exactly
    /// what this refuses to do elsewhere, and an agent using the CLI sets them properly.
    ///
    /// The meeting is read whole and handed to the prompt, which is what carries any summary that is
    /// already there — a re-run on a meeting the user has hand-edited revises their write-up rather
    /// than writing over it. The state move is `Meeting.setSummary`, the same rule the CLI runs.
    public func enhance(meetingID: String, store: MeetingStore) async throws {
        guard let meeting = try store.meeting(id: meetingID) else {
            throw StoreError.meetingNotFound(meetingID)
        }
        let summary = try await complete(
            system: CloudPrompt.system,
            user: CloudPrompt.user(
                meeting: meeting,
                notes: try store.notes(meetingID: meetingID),
                segments: try store.segments(meetingID: meetingID)
            )
        )
        guard !summary.isEmpty else { throw CloudEnhancementError.emptyResponse }
        try store.updateMeeting(id: meetingID) { $0.setSummary(summary) }
    }

    /// The request this mode sends, built in one place so ``AIVerify`` can probe the endpoint, the
    /// auth header and the body shape that a real write-up would use rather than a lookalike that is
    /// free to drift away from it — a verify against the wrong URL is worse than no verify at all.
    static func chatRequest(
        _ configuration: Configuration,
        messages: [[String: String]],
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": configuration.model, "messages": messages]
        if let maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func complete(system: String, user: String) async throws -> String {
        let request = try Self.chatRequest(configuration, messages: [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ])

        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudEnhancementError.http(http.statusCode, String(decoding: data.prefix(512), as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }
}

public enum CloudEnhancementError: Error, CustomStringConvertible {
    case http(Int, String)
    case emptyResponse

    public var description: String {
        switch self {
        case .http(let code, let body): "the provider returned HTTP \(code): \(body)"
        case .emptyResponse: "the provider returned no summary"
        }
    }
}
