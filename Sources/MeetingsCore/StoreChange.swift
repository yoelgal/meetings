import Foundation

/// The app and the CLI are two processes on one SQLite file, and GRDB's `ValueObservation` only
/// sees writes made inside its own process. So every commit is announced here: the CLI writes,
/// posts, and exits; an open app window hears it and refetches. Without this you write a summary
/// from your agent session and stare at stale data until you relaunch.
public enum StoreChange {
    public static let name = Notification.Name("com.yoelgal.Meetings.storeChanged")

    /// `userInfo` key holding the affected meeting id. Absent means "something broad changed" —
    /// a folder was renamed, vocabulary moved — and the listener should refetch everything.
    public static let meetingIDKey = "meetingId"

    /// `userInfo` key holding the database file the change landed in. A machine can have more than
    /// one store open — an acceptance run against `$MEETINGS_DB` while the real app is up — and a
    /// listener has no business refetching because some other database moved.
    public static let storePathKey = "storePath"

    /// `userInfo` key holding the posting process id. See ``observe(storePath:queue:handler:)``.
    public static let senderKey = "sender"

    private static let processID = String(ProcessInfo.processInfo.processIdentifier)

    /// Called *after* the transaction commits, never inside it. A listener that refetches on a
    /// notification posted mid-transaction reads the pre-commit state and caches it.
    public static func post(storePath: String, meetingID: String? = nil) {
        var userInfo = [storePathKey: storePath, senderKey: processID]
        userInfo[meetingIDKey] = meetingID

        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        // And locally, synchronously. Distributed delivery is a round trip through distnoted: right
        // for the other process, useless to anything in this one that needs to react now.
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Listens on both centres. Hold onto the returned token: the observers are removed when it
    /// deallocates, so dropping it on the floor silently stops the refreshes.
    ///
    /// distnoted echoes a notification back to the process that posted it, so an observer that
    /// listened to both centres naively would see every one of its own writes twice, at two
    /// unrelated moments. The echo is dropped by process id: a local post has already been
    /// delivered synchronously by the time its distributed twin comes back.
    ///
    /// `storePath` of nil hears every store, which is what a normal app or CLI wants — it has one
    /// store and so does everything else on the machine. Pass a path to ignore the others.
    /// `queue` of nil delivers on whichever thread posted; pass `.main` from UI code.
    public static func observe(
        storePath: String? = nil,
        queue: OperationQueue? = nil,
        handler: @escaping @Sendable (String?) -> Void
    ) -> Observation {
        @Sendable func deliver(_ note: Notification, droppingOwnPosts: Bool) {
            if droppingOwnPosts, note.userInfo?[senderKey] as? String == processID { return }
            if let storePath, note.userInfo?[storePathKey] as? String != storePath { return }
            handler(note.userInfo?[meetingIDKey] as? String)
        }

        let distributed = DistributedNotificationCenter.default()
        return Observation(tokens: [
            (
                distributed,
                distributed.addObserver(forName: name, object: nil, queue: queue) {
                    deliver($0, droppingOwnPosts: true)
                }
            ),
            (
                .default,
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue) {
                    deliver($0, droppingOwnPosts: false)
                }
            ),
        ])
    }

    /// Removes its observers on deinit so callers cannot leak them.
    public final class Observation {
        private let tokens: [(center: NotificationCenter, token: any NSObjectProtocol)]

        init(tokens: [(center: NotificationCenter, token: any NSObjectProtocol)]) {
            self.tokens = tokens
        }

        deinit {
            for (center, token) in tokens {
                center.removeObserver(token)
            }
        }
    }
}
