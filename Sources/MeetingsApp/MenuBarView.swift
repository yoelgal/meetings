import MeetingsCore
import SwiftUI

/// The menu bar item. Deliberately tiny: a recording state dot, Start/Stop, and a
/// quick-note field that writes to the active meeting. Nothing else, because during a call the main
/// window is behind Zoom and this is a remote control, not a second app.
///
/// The one addition is the nudge, which is the whole reason the icon has more than two
/// states: when a calendar event with a video link starts and nothing is recording, the icon goes
/// wrong on purpose and stays wrong until you start or dismiss it.
struct MenuBarView: View {
    @Bindable var model: AppModel

    @State private var quickNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.nudge.pending {
                NudgeRow(event: event) {
                    Task { await model.startNudgedRecording() }
                } dismiss: {
                    model.nudge.dismiss()
                }
                Divider()
            }

            HStack(spacing: 8) {
                if model.isRecording {
                    RecordingDot()
                    Text(model.activeMeeting?.title ?? "Recording")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                } else {
                    Circle()
                        .strokeBorder(.tertiary, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                    Text("Not recording")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if model.isRecording {
                    Button("Stop") { Task { await model.stopRecording() } }
                        .tint(.red)
                } else {
                    // "New meeting", not "Start": with a nudge above it, two buttons both saying
                    // Start are two different meetings one word apart, and the wrong one files the
                    // recording against nothing. Words rather than a bare plus, because at 280 pt
                    // there is room and this popover is read at a glance with a call on top of it.
                    // Same wording as the window's toolbar, same action.
                    Button("New meeting") { Task { await model.startAdHocMeeting() } }
                }
            }

            if model.isRecording {
                // Only when there is somewhere for it to land. A note field with no active meeting
                // would either lose what you typed or invent a meeting to hold it.
                TextField("Quick note", text: $quickNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(commitQuickNote)
            }
        }
        .padding(12)
        .frame(width: 280)
        // This menu closes the moment you click anywhere else, which during a call is constantly.
        // Return was the only thing that filed a note, so a half-typed one died with the popover
        // and never reached the store — the same way the window's note field used to lose them.
        .onDisappear(perform: commitQuickNote)
    }

    /// `addLiveNote` drops an empty or whitespace-only note itself, and with no argument it files
    /// against whatever is recording — which is the only thing this field is ever pointed at.
    private func commitQuickNote() {
        model.addLiveNote(quickNote)
        quickNote = ""
    }
}

/// No sound, no notification, no rolling buffer — a row in a menu you already had.
private struct NudgeRow: View {
    let event: CalendarEvent
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "video.badge.waveform")
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Text("Started at \(Format.timeOfDay(event.start)). Not recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Start recording") { start() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss", action: dismiss)
            }
        }
    }
}

extension AppModel {
    /// The menu bar icon. Three states and no more: idle, recording, and a nudge that is visibly
    /// not either of the other two.
    var menuBarSymbol: String {
        if isRecording { return "record.circle.fill" }
        if nudge.pending != nil { return "video.badge.waveform" }
        return "waveform"
    }
}
