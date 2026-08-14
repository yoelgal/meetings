import Foundation

/// A dotted version, compared as numbers rather than as text.
///
/// String comparison is the bug this type exists to avoid: `"1.10" < "1.9"` is true for a `String`
/// and false for a release, so a lexicographic check stops offering updates at the tenth patch and
/// never says why.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    /// Tolerant of the `v` that git tags conventionally carry and of a trailing pre-release or build
    /// suffix, so `v1.2.0`, `1.2.0` and `1.2.0-beta.1` all parse. Returns nil for anything with no
    /// leading number at all, which is how a tag that is not a version gets ignored instead of
    /// silently comparing as zero.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        components = parts.compactMap { $0 }
        description = String(core)
    }

    /// Missing trailing components are zero, so `1.2` and `1.2.0` are the same release. The app ships
    /// `CFBundleShortVersionString` in whichever form the tag used, and the two must not disagree.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    /// Written out rather than synthesised. The compiler's `==` compares the stored arrays, which
    /// makes `1.2` unequal to `1.2.0` while `<` says neither is smaller — a `Comparable` that
    /// contradicts itself, and every use of it a coin toss over which operator was reached for.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// A release newer than the one running.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    /// The release page, which is where a person goes to read what changed and how to get it.
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Asks GitHub, once a day at most, whether there is a newer release than the one running.
///
/// Deliberately *not* an updater. Nothing is downloaded, verified or installed: the app is built
/// from source and signed with a certificate generated in the builder's own keychain, so there is no
/// binary a restart could pick up, and swapping one in would reset the microphone and screen
/// recording grants that identity exists to keep. This tells you and links you to the release; the
/// README says what to run.
public enum UpdateCheck {
    /// The one place the repository is named. A fork that renames it changes this line and nothing
    /// else.
    public static let repository = "yoelgal/meetings"

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Once a day. A version check is not news that arrives faster than that, and anything more
    /// frequent is a request to GitHub that tells them you are awake for no benefit to you.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// What asked for the check, which is the only thing that decides the two gates.
    public enum Trigger: Sendable {
        /// App startup. Skips the interval: you have just relaunched, and a build you installed two
        /// hours ago being told it is current until tomorrow is the wrong answer.
        case launch
        /// The daily tick for a session left open. Honours the interval, which is the whole point
        /// of it.
        case periodic
        /// A button someone pressed. Runs whatever the setting says, because pressing it *is* the
        /// consent the setting exists to record, and reports the outcome either way.
        case manual

        var honoursInterval: Bool { self == .periodic }
        var requiresSetting: Bool { self != .manual }
    }

    /// Whether a check of this kind is allowed and due.
    public static func isDue(_ trigger: Trigger = .periodic, store: MeetingStore, now: Date = Date()) -> Bool {
        if trigger.requiresSetting, (try? store.settingBool(.updateCheckEnabled)) != true { return false }
        guard trigger.honoursInterval else { return true }
        guard let raw = try? store.setting(.updateLastCheckedAt), let seconds = TimeInterval(raw) else {
            return true
        }
        // A stored time in the future means the clock moved backwards, not that the check happened
        // later than now. Treating it as due beats waiting a day for the clock to catch up.
        let last = Date(timeIntervalSince1970: seconds)
        return last > now || now.timeIntervalSince(last) >= interval
    }

    /// What a check actually did, so a button can say it.
    ///
    /// The automatic paths only act on `.update` and ignore the rest, which keeps launch silent. A
    /// press cannot be silent: a button that does nothing visible is a button you press again.
    public enum Outcome: Sendable, Equatable {
        case update(AvailableUpdate)
        case upToDate
        /// Unreachable, rate-limited, or an answer we could not read. One sentence, never a raw error.
        case failed(String)
        /// Not due, or switched off. Only ever returned to an automatic caller.
        case skipped

        public var available: AvailableUpdate? {
            if case .update(let update) = self { return update }
            return nil
        }
    }

    /// The whole thing: gate, ask, record.
    ///
    /// Failure is reported rather than thrown, and the automatic callers drop it on the floor. An app
    /// that opens with an error because a network it never told you it needed was unreachable has
    /// made your morning worse to tell you nothing.
    @discardableResult
    public static func run(
        _ trigger: Trigger = .launch,
        store: MeetingStore,
        currentVersion: String,
        now: Date = Date(),
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> Outcome {
        guard isDue(trigger, store: store, now: now) else { return .skipped }
        // Recorded before the request, not after. A GitHub outage or an offline morning would
        // otherwise leave the timestamp untouched and turn "once a day" into a failing request on
        // every single launch.
        try? store.setSetting(.updateLastCheckedAt, String(now.timeIntervalSince1970))
        return await latest(currentVersion: currentVersion, transport: transport)
    }

    /// The request and the comparison, with no store and no gate, so a test can drive it directly.
    ///
    /// Every failure is one `.failed` sentence rather than a thrown error, because the only caller
    /// that shows it is a button and the only useful thing to put beside a button is a sentence.
    public static func latest(
        currentVersion: String,
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> Outcome {
        guard let current = AppVersion(currentVersion) else {
            // 0.0.0 from an untagged build parses fine, so reaching here means something stranger.
            return .failed("This build has no version number to compare.")
        }

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects an API request with no User-Agent outright, so this is not decoration.
        request.setValue("Meetings/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            return .failed("Could not reach GitHub. \(error.localizedDescription)")
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // 403 here is almost always the unauthenticated rate limit, 60 an hour per IP, and
            // "GitHub said 403" sends someone looking for a permissions problem they do not have.
            if code == 403 || code == 429 {
                return .failed("GitHub is rate-limiting this network. Try again later.")
            }
            return .failed("GitHub answered \(code).")
        }

        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              // `/releases/latest` is documented to exclude drafts and pre-releases, so a beta tag
              // never reaches here and the version parse does not have to rank one.
              let latest = AppVersion(release.tagName),
              let url = URL(string: release.htmlURL)
        else { return .failed("Could not read GitHub's answer.") }

        guard latest > current else { return .upToDate }
        return .update(AvailableUpdate(version: latest.description, url: url))
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
