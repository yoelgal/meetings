import Foundation
import MeetingsCore
import Observation

/// The passive nudge. When a calendar event with a video link reaches its start time and
/// nothing is recording, the menu bar icon changes and the menu offers to start that meeting.
///
/// What it deliberately does **not** do: capture audio, keep a rolling buffer, or post a
/// notification. The icon just sits there being wrong until you deal with it. Auto-start is v1.1.
@MainActor
@Observable
final class NudgeModel {
    /// The event worth nudging about, or nil. Read by the menu bar icon and the menu.
    private(set) var pending: CalendarEvent?

    private let store: MeetingStore
    private let calendarSource: any CalendarSource
    /// Dismissal is per-event — dismissing one meeting's nudge must not silence the next.
    /// ponytail: in-memory, so a relaunch mid-meeting nudges again. That is the right side to err
    /// on; persist it if it ever becomes annoying.
    private var dismissed: Set<String> = []
    private var poll: Task<Void, Never>?
    /// Set by the app while a recording is running: a nudge during a recording is noise.
    var recordingInProgress = false { didSet { if recordingInProgress { pending = nil } } }

    init(store: MeetingStore, calendarSource: any CalendarSource) {
        self.store = store
        self.calendarSource = calendarSource
    }

    /// Polls rather than observing: EventKit's change notification does not fire when an event
    /// merely *becomes current*, which is the entire trigger here. Thirty seconds is well inside
    /// the granularity anyone notices on a meeting start.
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func dismiss() {
        if let id = pending?.id { dismissed.insert(id) }
        pending = nil
    }

    /// Called when a recording starts, whatever started it: the nudge has served its purpose.
    func dismissForActiveRecording() {
        dismiss()
        recordingInProgress = true
    }

    func evaluate(now: Date = Date()) async {
        guard !recordingInProgress else {
            pending = nil
            return
        }
        // A short window either side of "now": far enough back to catch an event that started while
        // the app was launching, far enough forward that the icon changes as the meeting begins
        // rather than a minute into it.
        let events = (try? await calendarSource.events(
            from: now.addingTimeInterval(-4 * 3600),
            to: now.addingTimeInterval(120)
        )) ?? []

        pending = events.first { event in
            event.videoLink != nil
                && event.start <= now.addingTimeInterval(60)
                && event.end > now
                && !dismissed.contains(event.id)
                // Already recorded, or already being written up: nothing owed.
                && ((try? store.meeting(calendarEventID: event.id)) ?? nil)?.startedAt == nil
        }
    }
}
