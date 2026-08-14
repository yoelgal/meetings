import Foundation
import Testing

@testable import MeetingsCore

/// The summary is now editable in the app, which makes it the second column with two writers. These
/// cover the rule both of them run, so "the summary editor behaves like the pre-notes one" is a
/// property of one implementation rather than a hope about two.
@Suite struct SharedFieldEditTests {
    // MARK: - Two writers, one field

    @Test func ourOwnWriteComingBackIsRecognisedAsAnEcho() {
        // The store echoes every commit to every process, including the one that made it. Treating
        // that as somebody else's edit would put a conflict banner over every save the user makes.
        #expect(SharedFieldEdit.receive(
            incoming: "same", baseline: "same", text: "same", touched: false
        ) == .echo)
        #expect(SharedFieldEdit.receive(
            incoming: "same", baseline: "same", text: "typing…", touched: true
        ) == .echo)
    }

    @Test func anUntouchedFieldReloadsSilently() {
        #expect(SharedFieldEdit.receive(
            incoming: "the agent's write-up", baseline: "", text: "", touched: false
        ) == .reload)
    }

    @Test func aTouchedFieldIsNeverClobbered() {
        #expect(SharedFieldEdit.receive(
            incoming: "theirs", baseline: "was", text: "mine", touched: true
        ) == .conflict)
    }

    /// A save scheduled but not yet committed leaves the flag down while the field already differs.
    /// Reloading over that is exactly the clobber the flag is there to prevent.
    @Test func aPendingEditIsAConflictEvenBeforeTheFlagIsSet() {
        #expect(SharedFieldEdit.receive(
            incoming: "theirs", baseline: "was", text: "half-typed", touched: false
        ) == .conflict)
    }

    @Test func keepBothAppendsOnlyWhatIsNotAlreadyMine() {
        #expect(SharedFieldEdit.merge(mine: "a\nb", theirs: "b\nc") == "a\nb\nc")
        #expect(SharedFieldEdit.merge(mine: "a", theirs: "a") == "a", "nothing new is nothing to add")
        #expect(SharedFieldEdit.merge(mine: "", theirs: "theirs") == "theirs")
        #expect(SharedFieldEdit.merge(mine: "mine\n", theirs: "theirs") == "mine\ntheirs",
                "no blank line is invented where mine already ends in one")
    }

    // MARK: - Clearing a summary moves the meeting back

    /// The last two states are defined by whether a summary exists. The app can clear the field
    /// now, so a summary cleared in the window and one cleared by `meetings summary set <ref> ""`
    /// have to land in the same state — which is only true while there is one copy of this rule.
    @Test func writingASummaryCompletesAReadyMeetingAndClearingItMovesItBack() {
        var meeting = Meeting(title: "Standup", state: .ready)

        meeting.setSummary("We shipped the recorder.")
        #expect(meeting.summary == "We shipped the recorder.")
        #expect(meeting.state == .complete)

        meeting.setSummary("")
        #expect(meeting.summary == nil)
        #expect(meeting.state == .ready)
    }

    /// Absent and empty are the same state. A field the user selected and deleted leaves whitespace
    /// behind, and storing that would leave a meeting `complete` with nothing written on it.
    @Test(arguments: ["", "   ", "\n\n", nil]) func whitespaceIsNotAWriteUp(_ text: String?) {
        var meeting = Meeting(title: "Standup", state: .complete, summary: "something")
        meeting.setSummary(text)
        #expect(meeting.summary == nil)
        #expect(meeting.state == .ready)
    }

    /// Stored exactly as typed. The editor autosaves mid-sentence and then reads the field back to
    /// see whether anybody else wrote it: a store that trimmed the newline the user had just typed
    /// would hand it a value it did not write, and it would raise a conflict against itself.
    @Test func aWriteUpIsStoredExactlyAsGiven() {
        var meeting = Meeting(title: "Standup", state: .ready)
        meeting.setSummary("## Summary\nWe shipped it.\n\n")
        #expect(meeting.summary == "## Summary\nWe shipped it.\n\n")
    }

    /// The same rule from the other side: an editor clearing a field it had spaces in must not read
    /// the stored nothing back as somebody else's edit.
    @Test func blankAndAbsentAreTheSameValueToAnOpenEditor() {
        #expect(SharedFieldEdit.receive(
            incoming: "", baseline: "   \n", text: "   \n", touched: false
        ) == .echo)
    }

    /// Only the last two states move. A summary arriving on a meeting that is still recording says
    /// nothing about whether the recording has finished.
    @Test(arguments: [MeetingState.scheduled, .recording, .transcribing])
    func theOtherStatesAreLeftWhereTheyAre(_ state: MeetingState) {
        var meeting = Meeting(title: "Standup", state: state)
        meeting.setSummary("written up early")
        #expect(meeting.state == state)
        #expect(meeting.summary == "written up early")

        meeting.setSummary(nil)
        #expect(meeting.state == state)
    }
}
