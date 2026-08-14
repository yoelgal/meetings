import Foundation
import Testing

@testable import MeetingsCore

/// The verify buttons in the wizard and in Settings ▸ AI, and `meetings ai verify`, are all this one
/// function.
///
/// **Nothing in this file opens a socket or runs an agent.** The cloud transport is injected and the
/// local check is pointed at binaries every Mac has, which is the whole reason the check was built
/// to take a transport and a template rather than to read the world for itself.
@Suite struct AIVerifyTests {

    // MARK: - Mode B: what the check does and does not establish

    /// The wording is the feature. A tick that said "Verified" after resolving a path would be
    /// claiming a write-up path that has never been run once, so the sentence has to carry both
    /// halves: what was found, and that the command itself has not been executed.
    @Test func aFoundAgentSaysWhereItIsAndThatItWasNotRun() {
        let result = AIVerify.localAgent(template: "/bin/echo {meeting_id}", environment: [:])
        #expect(result.ok)
        #expect(result.message == "echo found at /bin/echo. The command is not run until a meeting finishes.")
    }

    /// The failure the button exists for: a GUI launch inherits four directories of PATH, so an
    /// agent installed by Homebrew or in ~/.local/bin is not found and Mode B silently does nothing.
    @Test func aBareNameIsSearchedOnThePATHTheRunnerActuallyLaunchesWith() throws {
        let directory = try TestStore.makeDirectory()
        let bin = directory.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("meetings-agent")
        try "#!/bin/sh\nexit 0\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        // HOME only: ~/.local/bin is reachable solely because the runner widens PATH, and this is
        // the check that the verify searches the widened one rather than the process's own.
        let result = AIVerify.localAgent(
            template: "meetings-agent {meeting_id}",
            environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        )
        #expect(result.ok)
        #expect(result.message == "meetings-agent found at \(agent.path). The command is not run until a meeting finishes.")
    }

    @Test func aMissingAgentSaysWhatWouldHappenRatherThanJustFailing() {
        let result = AIVerify.localAgent(
            template: "meetings-no-such-agent {meeting_id}",
            environment: ["HOME": "/nowhere", "PATH": "/usr/bin:/bin"]
        )
        #expect(!result.ok)
        #expect(result.message.contains("is not on the PATH Meetings searches"))
        #expect(result.message.contains("nothing would run when a meeting finishes"))
    }

    @Test func anAbsolutePathThatIsNotExecutableIsNamedInFull() throws {
        let directory = try TestStore.makeDirectory()
        let file = directory.appendingPathComponent("not-executable")
        try "text".write(to: file, atomically: true, encoding: .utf8)

        let result = AIVerify.localAgent(template: file.path, environment: [:])
        #expect(!result.ok)
        #expect(result.message == "\(file.path) is not an executable file, so nothing would run when a meeting finishes.")
    }

    @Test func anEmptyTemplateIsRefusedBeforeAnythingIsSearchedFor() {
        #expect(AIVerify.localAgent(template: "   ", environment: [:]).ok == false)
        #expect(AIVerify.localAgent(template: "", environment: [:]).message
            == "The command template is empty, so nothing would run when a meeting finishes.")
    }

    // MARK: - Mode C: the missing pieces, each named

    /// "Not configured" is useless when three things are needed. Each gap says which one it is, and
    /// none of them sends a request — the transport here fails the test if it is ever called.
    @Test func eachMissingCloudSettingIsNamedAndNothingIsSent() async {
        let refuse: HTTPTransport = { _ in
            Issue.record("a half-configured provider must not be contacted")
            throw URLError(.badURL)
        }
        let cases: [(String?, String?, String?, String?, String)] = [
            (nil, "gpt-4o-mini", "openai", "sk-live", "No base URL is set"),
            ("https://api.example.com/v1", nil, "openai", "sk-live", "No model is set"),
            ("https://api.example.com/v1", "gpt-4o-mini", nil, "sk-live", "No Keychain account is set"),
            ("https://api.example.com/v1", "gpt-4o-mini", "openai", nil,
             "No API key is in the Keychain under the account openai"),
        ]
        for (baseURL, model, keyRef, key, expected) in cases {
            let result = await AIVerify.cloud(
                baseURL: baseURL, model: model, keyRef: keyRef, key: key, transport: refuse
            )
            #expect(!result.ok)
            #expect(result.message.contains(expected), "got: \(result.message)")
        }
    }

    // MARK: - Mode C: the request that is actually sent

    /// The probe goes to the endpoint the write-up path uses, with the same auth header, capped at
    /// one token. A check against a different URL would pass while the real thing 404s.
    @Test func theProbeIsTheWriteUpPathsOwnRequest() async throws {
        let seen = Recorder()
        _ = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            keyRef: "openai",
            key: "sk-live-secret",
            transport: seen.transport(status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        )
        let request = try #require(await seen.request)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-live-secret")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["max_tokens"] as? Int == 1)
    }

    @Test func anAnsweringProviderReportsTheHostAndTheModelItAccepted() async {
        let result = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            keyRef: "openai",
            key: "sk-live-secret",
            transport: Recorder().transport(status: 200, body: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        )
        #expect(result.ok)
        #expect(result.message == "api.example.com answered and accepted the model gpt-4o-mini.")
    }

    /// A 200 from something that is not an OpenAI-compatible endpoint — a proxy's landing page, a
    /// base URL missing its /v1 — is not a working provider, and saying so beats a green tick.
    @Test func aTwoHundredThatIsNotAChatCompletionIsNotAPass() async {
        let result = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            keyRef: "openai",
            key: "sk-live-secret",
            transport: Recorder().transport(status: 200, body: "<html>hello</html>")
        )
        #expect(!result.ok)
        #expect(result.message.contains("not with an OpenAI-compatible chat completion"))
    }

    @Test func aRejectedModelComesBackInTheProvidersOwnWords() async {
        let result = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-9",
            keyRef: "openai",
            key: "sk-live-secret",
            transport: Recorder().transport(
                status: 404,
                body: #"{"error":{"message":"The model `gpt-9` does not exist."}}"#
            )
        )
        #expect(!result.ok)
        #expect(result.message == "api.example.com returned HTTP 404: The model `gpt-9` does not exist.")
    }

    @Test func anUnreachableHostIsNamedWithFoundationsOwnSentence() async {
        let result = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            keyRef: "openai",
            key: "sk-live-secret",
            transport: { _ in throw URLError(.cannotFindHost) }
        )
        #expect(!result.ok)
        #expect(result.message.hasPrefix("Could not reach api.example.com: "))
        #expect(result.message.hasSuffix("."))
    }

    // MARK: - The key never comes back out

    /// OpenAI's 401 body quotes the key it rejected straight back at you. Relaying an error body
    /// verbatim is therefore one of the ways an API key ends up in a screenshot or a bug report.
    @Test func aProviderEchoingTheKeyBackNeverReachesTheMessage() async {
        let key = "sk-proj-0123456789abcdefghij"
        let result = await AIVerify.cloud(
            baseURL: "https://api.example.com/v1",
            model: "gpt-4o-mini",
            keyRef: "openai",
            key: key,
            transport: Recorder().transport(
                status: 401,
                body: #"{"error":{"message":"Incorrect API key provided: sk-proj-0123456789abcdefghij. Check your key."}}"#
            )
        )
        #expect(!result.ok)
        #expect(result.message.hasPrefix("api.example.com rejected the API key"))
        #expect(!result.message.contains(key))
        #expect(!result.message.contains("sk-proj-0123"))
    }

    /// The partial echo, which is the shape a provider is most likely to use and the one an exact
    /// string match misses.
    @Test func aPartiallyMaskedKeyIsRedactedToo() {
        let scrubbed = AIVerify.redacting(
            "sk-proj-0123456789abcdefghij",
            in: "Incorrect API key provided: sk-proj-0123****ghij. You can find your key at ..."
        )
        #expect(!scrubbed.contains("sk-proj-0123"))
        #expect(scrubbed.contains("[redacted]"))
        // Only the key-shaped token goes: the rest of the sentence is what makes the result useful.
        #expect(scrubbed.contains("Incorrect API key provided"))
    }

    @Test func redactingLeavesOrdinaryProseAlone() {
        let scrubbed = AIVerify.redacting(
            "sk-proj-0123456789abcdefghij",
            in: "The model gpt-4o-mini-2024-07-18 does not exist."
        )
        #expect(scrubbed == "The model gpt-4o-mini-2024-07-18 does not exist.")
    }

    // MARK: - Whichever mode is armed

    @Test func manualSaysThereIsNothingToCheckRatherThanPassingSilently() async throws {
        let store = try TestStore.open(try TestStore.makeDirectory())
        let result = await AIVerify.mode(.manual, store: store)
        #expect(result.ok)
        #expect(result.message.contains("nothing runs on its own"))
    }

    /// The *executed* setting, never the pasteable one: checking `ai.manual.pasteCommand` would try
    /// to resolve `/meetings` as a binary and report the mode broken when it is fine.
    @Test func modeReadsTheStoresOwnRunCommandForTheLocalAgent() async throws {
        let store = try TestStore.open(try TestStore.makeDirectory())
        try store.setSetting(.aiLocalAgentRunCommand, "/bin/echo {meeting_id}")
        try store.setSetting(.aiManualPasteCommand, "/meetings {meeting_id}")
        let result = await AIVerify.mode(.localAgent, store: store)
        #expect(result.ok)
        #expect(result.message.contains("/bin/echo"))
    }
}

/// Holds the request the check sent, so a test can assert on it. An actor because the transport is
/// `@Sendable` and is called from whatever context the check runs on.
private actor Recorder {
    var request: URLRequest?

    func record(_ request: URLRequest) { self.request = request }

    nonisolated func transport(status: Int, body: String) -> HTTPTransport {
        { request in
            await self.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }
}
