import Foundation
import Testing

@testable import MeetingsCore

@Suite struct AppVersionTests {
    @Test func parsesTheFormsAGitTagActuallyTakes() {
        #expect(AppVersion("1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("  v2.0 ")?.components == [2, 0])
        // GitHub's /releases/latest excludes pre-releases, so this should never arrive — but a tag
        // read from anywhere else must not parse as nothing.
        #expect(AppVersion("1.2.3-beta.1")?.components == [1, 2, 3])
    }

    @Test func refusesWhatIsNotAVersion() {
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
    }

    /// The reason `AppVersion` exists rather than comparing the strings.
    ///
    /// `"1.10.0" < "1.9.0"` is true for a `String`. An app comparing tags lexicographically stops
    /// offering updates at the tenth minor release and gives no sign that it has: it just goes
    /// quiet, permanently, and looks exactly like being up to date.
    @Test func ordersByNumberNotByText() {
        #expect(AppVersion("1.9.0")! < AppVersion("1.10.0")!)
        #expect(AppVersion("1.2.0")! < AppVersion("1.2.1")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    /// A tag cut as `v1.2` and a plist reading `1.2.0` are the same release. Without this the app
    /// offers you an update to the version you are already running, every day, forever.
    @Test func missingTrailingComponentsAreZero() {
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(!(AppVersion("1.2")! < AppVersion("1.2.0")!))
        #expect(!(AppVersion("1.2.0")! < AppVersion("1.2")!))
    }
}

@Suite final class UpdateCheckTests {
    let directory: URL
    let store: MeetingStore

    static let now = Date(timeIntervalSince1970: 1_770_000_000)

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A transport that answers with one canned release and records what it was asked.
    private func transport(
        tag: String,
        status: Int = 200,
        seen: (@Sendable (URLRequest) -> Void)? = nil
    ) -> HTTPTransport {
        { request in
            seen?(request)
            let body = """
                {"tag_name": "\(tag)", "html_url": "https://github.com/x/y/releases/tag/\(tag)"}
                """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    // MARK: - The comparison

    @Test func reportsANewerRelease() async {
        let update = await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "v1.1.0"))
        #expect(update?.version == "1.1.0")
        #expect(update?.url.absoluteString == "https://github.com/x/y/releases/tag/v1.1.0")
    }

    @Test func staysQuietWhenCurrentOrAhead() async {
        #expect(await UpdateCheck.latest(currentVersion: "1.1.0", transport: transport(tag: "v1.1.0")) == nil)
        // A local build ahead of the last tag is not an update to itself.
        #expect(await UpdateCheck.latest(currentVersion: "1.2.0", transport: transport(tag: "v1.1.0")) == nil)
    }

    /// Every failure is nil, never a thrown error and never a notice. This runs unprompted at
    /// launch, so an offline morning must not put anything on screen.
    @Test func everyFailureIsSilent() async {
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "v9.0.0", status: 403)) == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "not-a-version")) == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: { _ in
            throw URLError(.notConnectedToInternet)
        }) == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: { request in
            (Data("{".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) == nil)
    }

    /// GitHub rejects an API request with no User-Agent outright, so a missing header would make
    /// every check fail in production while every test that stubs the transport still passed.
    @Test func sendsTheHeadersGitHubRequires() async {
        nonisolated(unsafe) var captured: URLRequest?
        _ = await UpdateCheck.latest(
            currentVersion: "1.0.0",
            transport: transport(tag: "v1.1.0", seen: { captured = $0 })
        )
        #expect(captured?.url?.absoluteString == "https://api.github.com/repos/\(UpdateCheck.repository)/releases/latest")
        #expect(captured?.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
        #expect(captured?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    // MARK: - The gate

    @Test func offMeansNoRequestAtAll() async {
        try! store.setSetting(.updateCheckEnabled, "false")
        nonisolated(unsafe) var asked = false
        let update = await UpdateCheck.run(
            store: store, currentVersion: "1.0.0", now: Self.now,
            transport: transport(tag: "v2.0.0", seen: { _ in asked = true })
        )
        #expect(update == nil)
        #expect(asked == false, "a switched-off check must not touch the network")
    }

    @Test func checksAtMostOncePerDay() async {
        let first = await UpdateCheck.run(
            store: store, currentVersion: "1.0.0", now: Self.now, transport: transport(tag: "v2.0.0")
        )
        #expect(first != nil)

        nonisolated(unsafe) var asked = false
        let soon = await UpdateCheck.run(
            store: store, currentVersion: "1.0.0", now: Self.now.addingTimeInterval(3600),
            transport: transport(tag: "v2.0.0", seen: { _ in asked = true })
        )
        #expect(soon == nil)
        #expect(asked == false)

        let tomorrow = await UpdateCheck.run(
            store: store, currentVersion: "1.0.0",
            now: Self.now.addingTimeInterval(UpdateCheck.interval + 1), transport: transport(tag: "v2.0.0")
        )
        #expect(tomorrow != nil)
    }

    /// The timestamp is written before the request, not after it. Recording only successes would
    /// turn "once a day" into a failing request on every launch for anyone offline, which is both
    /// the least useful case and the one that pays for it.
    @Test func aFailedCheckStillCountsAsHavingChecked() async {
        _ = await UpdateCheck.run(
            store: store, currentVersion: "1.0.0", now: Self.now,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(UpdateCheck.isDue(store: store, now: Self.now.addingTimeInterval(60)) == false)
    }

    /// A clock that moved backwards leaves a stored time in the future. Waiting for now to catch up
    /// could mean no check for as long as the clock was wrong.
    @Test func aClockThatWentBackwardsDoesNotWedgeTheCheck() async {
        try! store.setSetting(.updateLastCheckedAt, String(Self.now.timeIntervalSince1970))
        #expect(UpdateCheck.isDue(store: store, now: Self.now.addingTimeInterval(-86_400 * 7)))
    }

    @Test func defaultsToOn() {
        #expect(try! store.settingBool(.updateCheckEnabled) == true)
        #expect(UpdateCheck.isDue(store: store, now: Self.now), "a store that has never checked is due")
    }
}
