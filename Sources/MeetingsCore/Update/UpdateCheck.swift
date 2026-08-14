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

    /// Whether a check is allowed and due. Both halves matter: the setting is the user's answer, the
    /// interval is the promise that saying yes does not mean a request every launch.
    public static func isDue(store: MeetingStore, now: Date = Date()) -> Bool {
        guard (try? store.settingBool(.updateCheckEnabled)) == true else { return false }
        guard let raw = try? store.setting(.updateLastCheckedAt), let seconds = TimeInterval(raw) else {
            return true
        }
        // A stored time in the future means the clock moved backwards, not that the check happened
        // later than now. Treating it as due beats waiting a day for the clock to catch up.
        let last = Date(timeIntervalSince1970: seconds)
        return last > now || now.timeIntervalSince(last) >= interval
    }

    /// The whole thing: gate, ask, record. Returns nil when there is nothing to say, which covers a
    /// check that is not due, a check that is switched off, being up to date, and every possible
    /// failure.
    ///
    /// Failure is silent on purpose. This runs unprompted at launch, and an app that opens with an
    /// error because a network it never told you it needed was unreachable has made your morning
    /// worse to tell you nothing.
    @discardableResult
    public static func run(
        store: MeetingStore,
        currentVersion: String,
        now: Date = Date(),
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> AvailableUpdate? {
        guard isDue(store: store, now: now) else { return nil }
        // Recorded before the request, not after. A GitHub outage or an offline morning would
        // otherwise leave the timestamp untouched and turn "once a day" into a failing request on
        // every single launch.
        try? store.setSetting(.updateLastCheckedAt, String(now.timeIntervalSince1970))
        return await latest(currentVersion: currentVersion, transport: transport)
    }

    /// The request and the comparison, with no store and no gate, so a test can drive it directly.
    public static func latest(
        currentVersion: String,
        transport: HTTPTransport = AIVerify.liveTransport
    ) async -> AvailableUpdate? {
        guard let current = AppVersion(currentVersion) else { return nil }

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects an API request with no User-Agent outright, so this is not decoration.
        request.setValue("Meetings/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await transport(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              // `/releases/latest` is documented to exclude drafts and pre-releases, so a beta tag
              // never reaches here and the version parse does not have to rank one.
              let latest = AppVersion(release.tagName),
              latest > current,
              let url = URL(string: release.htmlURL)
        else { return nil }

        return AvailableUpdate(version: latest.description, url: url)
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
