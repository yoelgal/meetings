import Foundation

/// What one press of a verify button established — and, in the same sentence, what it did not.
///
/// The sentence *is* the result. A bare tick beside the word "Verified" is the thing this type
/// exists to prevent: Mode B is never executed by a check (see ``AIVerify/localAgent(template:environment:)``),
/// so a green tick on its own would claim a working write-up path that has never been run once.
public struct AIVerification: Sendable, Equatable {
    /// Whether the thing checked came back working. Not "the mode works end to end" — read the
    /// message for how far the check actually went.
    public let ok: Bool
    /// One sentence, in the user's terms, saying what happened. Never contains the API key.
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// The transport a cloud check sends its one request over.
///
/// A closure rather than a `URLSession` so a test can assert the request's URL, headers and body
/// without a socket — the alternative is a test suite that either hits a real provider or proves
/// nothing about the request that is actually sent.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Checks that the configured write-up mode would actually work, on demand and only on demand.
///
/// Nothing here runs on launch or on a timer: the cloud check is a real request to the user's own
/// endpoint and the local check reads their filesystem, and neither is something an app should do
/// behind someone's back.
public enum AIVerify {
    public static let liveTransport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    /// Checks whichever mode the store has armed. The one entry point the app's two panes and the
    /// CLI all call, so all three can only ever report the same thing.
    public static func mode(
        _ mode: AIMode,
        store: MeetingStore,
        transport: HTTPTransport = liveTransport
    ) async -> AIVerification {
        switch mode {
        case .manual:
            AIVerification(
                ok: true,
                message: "AI mode is manual, so nothing runs on its own and there is nothing to check."
            )
        case .localAgent:
            localAgent(store: store)
        case .cloud:
            await cloud(store: store, transport: transport)
        }
    }

    // MARK: - Mode B

    public static func localAgent(
        store: MeetingStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIVerification {
        localAgent(template: EnhancementRunner.commandTemplate(in: store), environment: environment)
    }

    /// Mode B, checked as far as it can honestly be checked without spending anything.
    ///
    /// The command is deliberately **not** run. Running it would write a summary over a real
    /// meeting, spend the user's agent subscription, and — for a CLI that expects a terminal — could
    /// sit waiting on a session nobody is watching. What is left is worth checking on its own,
    /// because it is the failure that actually happens: a GUI launch inherits a four-directory PATH,
    /// so the agent binary is simply not found, and today that surfaces only as a summary that never
    /// appears. The sentence says both halves, which is the whole point of the button.
    public static func localAgent(
        template: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIVerification {
        let consequence = "so nothing would run when a meeting finishes"
        guard let first = EnhancementRunner.tokenize(template).first, !first.isEmpty else {
            return AIVerification(ok: false, message: "The command template is empty, \(consequence).")
        }
        let name = first.contains("/") ? URL(fileURLWithPath: first).lastPathComponent : first
        guard let path = executable(first, searchPath: EnhancementRunner.searchPath(in: environment)) else {
            return AIVerification(
                ok: false,
                message: first.contains("/")
                    ? "\(first) is not an executable file, \(consequence)."
                    : "\(name) is not on the PATH Meetings searches, \(consequence)."
            )
        }
        return AIVerification(
            ok: true,
            message: "\(name) found at \(path). The command is not run until a meeting finishes."
        )
    }

    /// Resolved the way `/usr/bin/env` resolves it, because that is what actually launches the
    /// command: a name containing a slash is a path, anything else is searched for on PATH.
    private static func executable(_ name: String, searchPath: String) -> String? {
        let manager = FileManager.default
        if name.contains("/") {
            let path = URL(fileURLWithPath: name).path
            return manager.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Mode C

    public static func cloud(
        store: MeetingStore,
        transport: HTTPTransport = liveTransport
    ) async -> AIVerification {
        let keyRef = (try? store.setting(.aiCloudKeyRef)) ?? nil
        return await cloud(
            baseURL: (try? store.setting(.aiCloudBaseURL)) ?? nil,
            model: (try? store.setting(.aiCloudModel)) ?? nil,
            keyRef: keyRef,
            key: keyRef.flatMap { MeetingsKeychain.secret(account: $0) },
            transport: transport
        )
    }

    /// One real request to the user's own endpoint, over the same request builder the write-up path
    /// uses, so what comes back is about the configuration rather than about a lookalike request.
    ///
    /// `max_tokens: 1` because the answer is not read: reachable, authenticated and model accepted
    /// are all decided by the status code, and a provider that bills by the token should be billed
    /// as close to nothing as the API allows for a button press.
    ///
    /// `key` is passed in already fetched rather than read here, so a test can drive every branch
    /// without the login Keychain.
    public static func cloud(
        baseURL: String?,
        model: String?,
        keyRef: String?,
        key: String?,
        transport: HTTPTransport = liveTransport
    ) async -> AIVerification {
        let configuration: CloudEnhancer.Configuration
        switch cloudSetup(baseURL: baseURL, model: model, keyRef: keyRef, key: key) {
        case .missing(let sentence):
            return AIVerification(ok: false, message: sentence)
        case .ready(let resolved):
            configuration = resolved
        }

        let host = host(of: configuration)
        let request: URLRequest
        do {
            request = try CloudEnhancer.chatRequest(
                configuration,
                messages: [["role": "user", "content": "ping"]],
                maxTokens: 1
            )
        } catch {
            return AIVerification(ok: false, message: "The request could not be built, so nothing was sent.")
        }

        do {
            let (data, response) = try await transport(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return AIVerification(
                    ok: false,
                    message: httpSentence(host: host, code: code, body: data, key: configuration.apiKey)
                )
            }
            guard let probe = try? JSONDecoder().decode(ChatProbe.self, from: data), !probe.choices.isEmpty else {
                return AIVerification(
                    ok: false,
                    message: "\(host) answered, but not with an OpenAI-compatible chat completion."
                )
            }
            return AIVerification(ok: true, message: "\(host) answered and accepted the model \(configuration.model).")
        } catch {
            return AIVerification(ok: false, message: "Could not reach \(host): \(sentence(for: error)).")
        }
    }

    /// Mode C's four settings rows resolved once: either a configuration that can be used, or the
    /// one sentence naming the first piece that is missing.
    ///
    /// One chain, consulted by the verify button and by the unattended write-up alike. Two chains
    /// would drift, and the drift a user actually feels is "Settings verified fine, and nothing was
    /// written when the meeting finished".
    enum CloudSetup: Sendable {
        case ready(CloudEnhancer.Configuration)
        case missing(String)
    }

    static func cloudSetup(baseURL: String?, model: String?, keyRef: String?, key: String?) -> CloudSetup {
        guard let baseURL, !baseURL.isEmpty, let url = URL(string: baseURL), url.scheme != nil else {
            return .missing("No base URL is set, so there is no endpoint to call.")
        }
        guard let model, !model.isEmpty else {
            return .missing("No model is set, so nothing was sent.")
        }
        guard let keyRef, !keyRef.isEmpty else {
            return .missing("No Keychain account is set, so there is no API key to send.")
        }
        guard let key, !key.isEmpty else {
            return .missing("No API key is in the Keychain under the account \(keyRef), so nothing was sent.")
        }
        return .ready(CloudEnhancer.Configuration(baseURL: url, model: model, apiKey: key))
    }

    /// The sentence an unattended Mode C write-up failed with, in the verify button's own words.
    ///
    /// Same words on purpose: a user who presses Verify after a meeting failed to write itself up
    /// has to be able to tell that they are looking at the same problem, not a second one.
    ///
    /// Scrubbed on the way out whatever the branch. A provider's 401 body quotes the rejected key
    /// straight back (see ``redacting(_:in:)``), and this failure is written to the window without
    /// anybody having pressed anything, which is the copy most likely to end up in a screenshot.
    static func cloudFailure(_ error: Error, configuration: CloudEnhancer.Configuration) -> String {
        let host = host(of: configuration)
        let raw: String
        switch error as? CloudEnhancementError {
        case .http(let code, let body):
            raw = httpSentence(host: host, code: code, body: Data(body.utf8), key: configuration.apiKey)
        case .emptyResponse:
            raw = "\(host) answered without a summary, so nothing was written."
        case nil:
            raw = error is URLError
                ? "Could not reach \(host): \(sentence(for: error))."
                : "\(host) answered, but the write-up could not be completed: \(sentence(for: error))."
        }
        return redacting(configuration.apiKey, in: raw)
    }

    /// One wording for a provider that answered with a failure, so a 401 reads the same whether it
    /// came back from the verify button or from a meeting writing itself up.
    private static func httpSentence(host: String, code: Int, body: Data, key: String) -> String {
        let detail = providerMessage(body, key: key).map { ": \($0)" } ?? ""
        if code == 401 || code == 403 {
            return "\(host) rejected the API key\(detail)."
        }
        return "\(host) returned HTTP \(code)\(detail)."
    }

    /// What the user calls their provider. The host alone, because that is the part they typed and
    /// the part they recognise; the full URL only when there is no host to name.
    private static func host(of configuration: CloudEnhancer.Configuration) -> String {
        configuration.baseURL.host() ?? configuration.baseURL.absoluteString
    }

    /// Only the shape a success has to have. Decoding the content would be reading a reply the check
    /// deliberately capped at one token.
    private struct ChatProbe: Decodable {
        struct Choice: Decodable {}
        let choices: [Choice]
    }

    private struct ProviderError: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }

    /// The provider's own words for the failure, scrubbed and capped, or nil when the body says
    /// nothing worth relaying.
    private static func providerMessage(_ data: Data, key: String) -> String? {
        let raw = (try? JSONDecoder().decode(ProviderError.self, from: data))?.error.message
            ?? String(decoding: data.prefix(512), as: UTF8.self)
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        let scrubbed = redacting(key, in: flat)
        let capped = scrubbed.count > 160 ? String(scrubbed.prefix(160)) + "…" : scrubbed
        // The caller ends the sentence, and a provider's message usually ends it too.
        return capped.hasSuffix(".") ? String(capped.dropLast()) : capped
    }

    /// Takes anything that could be the API key back out of a provider's error prose before it is
    /// shown or logged.
    ///
    /// OpenAI's 401 body quotes the key it rejected straight back at you — "Incorrect API key
    /// provided: sk-proj-****abc" — so relaying an error body verbatim is one of the ways a key ends
    /// up in a screenshot or a bug report. The exact string is removed, and so is any token sharing
    /// the key's opening characters, which is what catches the provider's own partial echo.
    ///
    /// ponytail: a prefix match, not a secret detector. It covers the echo shape every provider
    /// actually uses; a provider that invented a new way to quote a key back would need it widened.
    static func redacting(_ key: String, in text: String) -> String {
        let withoutExact = text.replacingOccurrences(of: key, with: "[redacted]")
        let opening = String(key.prefix(6))
        guard opening.count == 6 else { return withoutExact }
        return withoutExact
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token in
                let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:'\"()[]"))
                return bare.count >= 8 && bare.hasPrefix(opening) ? "[redacted]" : String(token)
            }
            .joined(separator: " ")
    }

    /// Foundation writes a usable sentence for a URL failure — "A server with the specified hostname
    /// could not be found." — and it already ends in a full stop the caller is about to add again.
    static func sentence(for error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}
