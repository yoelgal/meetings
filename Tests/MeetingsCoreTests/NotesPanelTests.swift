import Foundation
import Testing

@testable import MeetingsCore

/// The floating notes panel writes through exactly the same store call the window's note field
/// writes through — `addNote(meetingID:tOffsetMs:text:)` at the recording clock — so what these
/// cover is the contract both surfaces depend on: the offset is the recording clock, and the anchor
/// is resolved by the store with the rule the batch pass will reuse.
///
/// The panel's own views live in the `MeetingsApp` executable target, which the test target does
/// not link (and `Package.swift` is not this unit's to change), so the view layer is proven by
/// running the real app instead — see the run record.
final class NotesPanelTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// A meeting mid-recording with two spoken turns, one on each channel.
    private func recordingMeeting() throws -> Meeting {
        let meeting = TestStore.meeting(state: .recording, startedAt: TestStore.referenceDate)
        try store.createMeeting(meeting)
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, channel: .system, from: 0, to: 9_000,
            text: "So the ptychography rig lands next week."
        ))
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, channel: .mic, from: 12_000, to: 20_000,
            text: "Then we can start the Torch0 calibration."
        ))
        return meeting
    }

    @Test("A note typed in the panel lands at the recording clock, anchored to what was being said")
    func noteFromPanelAnchors() throws {
        let meeting = try recordingMeeting()
        let covering = try store.segments(meetingID: meeting.id).first { $0.tStartMs == 12_000 }

        // 14.2 s in — the offset the panel reads off the recording clock the moment Return is hit.
        let note = try store.addNote(
            meetingID: meeting.id, tOffsetMs: 14_200, text: "chase the calibration jig"
        )

        #expect(note.tOffsetMs == 14_200)
        #expect(note.anchorSegmentID == covering?.id)
        #expect(try store.notes(meetingID: meeting.id).map(\.text) == ["chase the calibration jig"])
    }

    @Test("The panel and the window write into the same list, in clock order")
    func panelAndWindowShareOneList() throws {
        let meeting = try recordingMeeting()

        // One from the window's pane, one from the panel, at different points in the call.
        _ = try store.addNote(meetingID: meeting.id, tOffsetMs: 3_000, text: "typed in the window")
        _ = try store.addNote(meetingID: meeting.id, tOffsetMs: 15_500, text: "typed in the panel")

        let notes = try store.notes(meetingID: meeting.id)
        #expect(notes.map(\.text) == ["typed in the window", "typed in the panel"])
        // Different moments in the call anchor to different sentences: the anchor is not a
        // per-surface accident, it is the clock.
        #expect(notes[0].anchorSegmentID != notes[1].anchorSegmentID)
    }

    @Test("A note written before anybody has spoken still resolves to an anchor")
    func noteAtZeroStillAnchors() throws {
        let meeting = try recordingMeeting()
        let first = try store.segments(meetingID: meeting.id).first { $0.tStartMs == 0 }

        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: 0, text: "agenda point one")

        #expect(note.tOffsetMs == 0)
        #expect(note.anchorSegmentID == first?.id)
    }

    /// The panel's two settings are rows in the same table as everything else rather than private
    /// window state, which is what makes them survive a reinstall and readable by anything holding
    /// the store.
    @Test("The panel's settings round-trip through the settings table and default to on")
    func settingsRoundTrip() throws {
        let hide = SettingKey("panel.hideFromScreenSharing")
        let float = SettingKey("panel.keepAboveOtherApps")

        // Absent means on — the app supplies the default, and both defaults are protective.
        #expect(try store.settingBool(hide) == nil)
        #expect(try store.settingBool(float) == nil)

        try store.setSetting(hide, "false")
        try store.setSetting(float, "false")
        #expect(try store.settingBool(hide) == false)
        #expect(try store.settingBool(float) == false)
    }
}
