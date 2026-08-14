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
        let outcome = await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "v1.1.0"))
        #expect(outcome.available?.version == "1.1.0")
        #expect(outcome.available?.url.absoluteString == "https://github.com/x/y/releases/tag/v1.1.0")
    }

    @Test func staysQuietWhenCurrentOrAhead() async {
        #expect(await UpdateCheck.latest(currentVersion: "1.1.0", transport: transport(tag: "v1.1.0")) == .upToDate)
        // A local build ahead of the last tag is not an update to itself.
        #expect(await UpdateCheck.latest(currentVersion: "1.2.0", transport: transport(tag: "v1.1.0")) == .upToDate)
    }

    /// Every failure is nil, never a thrown error and never a notice. This runs unprompted at
    /// launch, so an offline morning must not put anything on screen.
    @Test func everyFailureIsSilent() async {
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "v9.0.0", status: 403)).available == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: transport(tag: "not-a-version")).available == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: { _ in
            throw URLError(.notConnectedToInternet)
        }).available == nil)
        #expect(await UpdateCheck.latest(currentVersion: "1.0.0", transport: { request in
            (Data("{".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }).available == nil)
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
        let outcome = await UpdateCheck.run(
            .periodic, store: store, currentVersion: "1.0.0", now: Self.now,
            transport: transport(tag: "v2.0.0", seen: { _ in asked = true })
        )
        #expect(outcome == .skipped)
        #expect(asked == false, "a switched-off check must not touch the network")
    }

    @Test func checksAtMostOncePerDay() async {
        let first = await UpdateCheck.run(
            .periodic, store: store, currentVersion: "1.0.0", now: Self.now, transport: transport(tag: "v2.0.0")
        )
        #expect(first.available != nil)

        nonisolated(unsafe) var asked = false
        let soon = await UpdateCheck.run(
            .periodic, store: store, currentVersion: "1.0.0", now: Self.now.addingTimeInterval(3600),
            transport: transport(tag: "v2.0.0", seen: { _ in asked = true })
        )
        #expect(soon == .skipped)
        #expect(asked == false)

        let tomorrow = await UpdateCheck.run(
            .periodic, store: store, currentVersion: "1.0.0",
            now: Self.now.addingTimeInterval(UpdateCheck.interval + 1), transport: transport(tag: "v2.0.0")
        )
        #expect(tomorrow.available != nil)
    }

    /// The timestamp is written before the request, not after it. Recording only successes would
    /// turn "once a day" into a failing request on every launch for anyone offline, which is both
    /// the least useful case and the one that pays for it.
    @Test func aFailedCheckStillCountsAsHavingChecked() async {
        _ = await UpdateCheck.run(
            .periodic, store: store, currentVersion: "1.0.0", now: Self.now,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(UpdateCheck.isDue(.periodic, store: store, now: Self.now.addingTimeInterval(60)) == false)
    }

    /// A clock that moved backwards leaves a stored time in the future. Waiting for now to catch up
    /// could mean no check for as long as the clock was wrong.
    @Test func aClockThatWentBackwardsDoesNotWedgeTheCheck() async {
        try! store.setSetting(.updateLastCheckedAt, String(Self.now.timeIntervalSince1970))
        #expect(UpdateCheck.isDue(.periodic, store: store, now: Self.now.addingTimeInterval(-86_400 * 7)))
    }

    // MARK: - What each trigger is allowed to do

    /// Launch ignores the daily interval.
    ///
    /// It used to honour it, which made the most likely moment to want a check the one moment it
    /// would not run: you relaunch *because* you just updated, or because something looked wrong,
    /// and the app tells you nothing until tomorrow.
    @Test func launchChecksEvenIfOneRanMinutesAgo() async {
        _ = await UpdateCheck.run(.launch, store: store, currentVersion: "1.0.0", now: Self.now,
                                  transport: transport(tag: "v2.0.0"))
        let again = await UpdateCheck.run(
            .launch, store: store, currentVersion: "1.0.0", now: Self.now.addingTimeInterval(60),
            transport: transport(tag: "v2.0.0")
        )
        #expect(again.available?.version == "2.0.0", "a relaunch must not be told to wait a day")
    }

    /// But launch still obeys the switch. "Every startup" is about the interval, not about consent.
    @Test func launchStillRespectsTheSetting() async {
        try! store.setSetting(.updateCheckEnabled, "false")
        nonisolated(unsafe) var asked = false
        let outcome = await UpdateCheck.run(
            .launch, store: store, currentVersion: "1.0.0", now: Self.now,
            transport: transport(tag: "v2.0.0", seen: { _ in asked = true })
        )
        #expect(outcome == .skipped)
        #expect(asked == false)
    }

    /// A press runs even with automatic checks switched off, because pressing it is the consent.
    @Test func manualRunsWithAutomaticChecksOff() async {
        try! store.setSetting(.updateCheckEnabled, "false")
        let outcome = await UpdateCheck.run(.manual, store: store, currentVersion: "1.0.0",
                                            now: Self.now, transport: transport(tag: "v2.0.0"))
        #expect(outcome.available?.version == "2.0.0")
    }

    /// And a press ignores the interval, or the button does nothing for a day after launch checked.
    @Test func manualIgnoresTheInterval() async {
        _ = await UpdateCheck.run(.launch, store: store, currentVersion: "1.0.0", now: Self.now,
                                  transport: transport(tag: "v2.0.0"))
        let pressed = await UpdateCheck.run(
            .manual, store: store, currentVersion: "1.0.0", now: Self.now.addingTimeInterval(5),
            transport: transport(tag: "v2.0.0")
        )
        #expect(pressed.available != nil)
    }

    /// A press has to be able to say "nothing to do" and "that did not work", not just go quiet.
    @Test func everyOutcomeIsDistinguishable() async {
        #expect(await UpdateCheck.latest(currentVersion: "9.9.9", transport: transport(tag: "v1.0.0"))
                == .upToDate)
        let offline = await UpdateCheck.latest(currentVersion: "1.0.0",
                                               transport: { _ in throw URLError(.notConnectedToInternet) })
        if case .failed(let why) = offline {
            #expect(!why.isEmpty)
        } else {
            Issue.record("an unreachable network should be .failed, got \(offline)")
        }
        // 403 unauthenticated is the rate limit, and saying "403" sends people hunting for a
        // permissions problem they do not have.
        let limited = await UpdateCheck.latest(currentVersion: "1.0.0",
                                               transport: transport(tag: "v2.0.0", status: 403))
        if case .failed(let why) = limited {
            #expect(why.lowercased().contains("rate"), "a 403 should be named as rate limiting: \(why)")
        } else {
            Issue.record("403 should be .failed, got \(limited)")
        }
    }

    @Test func defaultsToOn() {
        #expect(try! store.settingBool(.updateCheckEnabled) == true)
        #expect(UpdateCheck.isDue(.periodic, store: store, now: Self.now), "a store that has never checked is due")
    }
}
