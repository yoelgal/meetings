import AppKit
import MeetingsCore
import SwiftUI

/// The middle column: meetings in the selected scope, newest first, grouped by the day they
/// happened. Upcoming is the one scope that runs forwards and groups by calendar day; its rows are
/// store rows like every other scope's, because a calendar meeting gets one as soon as it appears.
struct MeetingListView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.scope == .upcoming {
                upcoming
            } else {
                meetings
            }
        }
        // The list yields first. At a half-screen 760 pt window the sidebar and this column used to
        // keep 575 pt between them while the detail column collapsed to ~185 pt — a large title
        // truncated mid-word and a summary ragging at four words a line. A row here is a title and
        // one line of metadata, both already truncated to one line, so 200 pt costs it far less
        // than 185 pt costs the thing you are actually reading.
        .navigationSplitViewColumnWidth(min: 200, ideal: 300, max: 420)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .columnTrailingHairline()
    }

    @ViewBuilder
    private var meetings: some View {
        if !model.loaded {
            LoadingStateView(message: "Loading meetings…")
        } else if model.meetings.isEmpty {
            EmptyStateView(
                symbol: model.scope.symbol,
                title: emptyTitle,
                message: emptyMessage,
                actionTitle: canStartHere ? "Start a meeting" : nil,
                action: { Task { await model.startAdHocMeeting() } }
            )
        } else {
            List(selection: $model.selection) {
                ForEach(model.groupedMeetings) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(
                                title: meeting.title,
                                metadata: Format.metadata(
                                    for: meeting,
                                    // Needs write-up implies `ready`, and the Scheduled bucket
                                    // implies `scheduled`. Either way the header above the row has
                                    // already said it.
                                    statedByScope: model.scope == .needsWriteUp
                                        || group.label == meeting.state.label
                                ),
                                incomplete: model.meetingsWithTranscriptIssues.contains(meeting.id)
                            )
                                .tag(meeting.id)
                                // Filing by drag. The payload is the meeting id;
                                // the sidebar's folder rows are the only thing that accepts it.
                                .draggable(meeting.id) {
                                    Label(meeting.title, systemImage: "waveform")
                                        .padding(6)
                                }
                                // Right-click and two-finger click. Everything it offers, and which
                                // items are honest for this particular row, lives in
                                // `MeetingActions.swift`.
                                .meetingContextMenu(model: model, meeting: meeting)
                        }
                    } header: {
                        DayHeader(label: group.label)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.inset)
            // Section separators are full-bleed and heavier than the inset row hairlines — they
            // read as a weight change under "Today". One tint, rows only.
            .listSectionSeparator(.hidden)
            .listRowSeparatorTint(Color.primary.opacity(0.14))
            .transcriptIssueLegend(shownWhen: model.meetings.contains {
                model.meetingsWithTranscriptIssues.contains($0.id)
            })
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        if !model.upcomingLoaded {
            LoadingStateView(message: "Loading calendar…")
        } else if model.calendarAuthorization != .authorized {
            EmptyStateView(
                symbol: "calendar.badge.exclamationmark",
                title: "Calendar access is off",
                // No written-out path: the button below opens the exact pane, so spelling out how
                // to walk there by hand is instructions for the thing the button already does.
                message: "Allow calendar access to show upcoming meetings.",
                actionTitle: "Open System Settings",
                action: {
                    if let url = Permission.calendar.settingsURL { NSWorkspace.shared.open(url) }
                }
            )
        } else if model.upcoming.isEmpty {
            EmptyStateView(
                symbol: "calendar",
                title: "Nothing coming up",
                // Keeps the fact that does the work. Without it, a full calendar showing an empty
                // list reads as a bug rather than as the filter doing its job. The window is a
                // setting now, so the sentence no longer names seven days.
                message: "Only events with meeting links appear here."
            )
        } else {
            List(selection: $model.selection) {
                ForEach(model.upcomingGroups) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            // Not dimmed. Wave 2 drew the whole of Upcoming at .secondary/.tertiary,
                            // which is the platform's vocabulary for *disabled*, not for *future* —
                            // Calendar does not grey out next week. The day header says when.
                            MeetingRow(title: meeting.title, metadata: upcomingMetadata(meeting))
                                .tag(meeting.id)
                                // Upcoming rows are store rows, so everything the other lists can do
                                // to a meeting works here too — filing it before it happens is the
                                // one people actually want.
                                .draggable(meeting.id) {
                                    Label(meeting.title, systemImage: "calendar")
                                        .padding(6)
                                }
                                .meetingContextMenu(model: model, meeting: meeting)
                        }
                    } header: {
                        DayHeader(label: group.label)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .listSectionSeparator(.hidden)
            .listRowSeparatorTint(Color.primary.opacity(0.14))
        }
    }

    /// No "Not recorded" tail: every row in Upcoming is unrecorded by definition, so it was a word
    /// repeated once per row that told nobody anything.
    private func upcomingMetadata(_ meeting: Meeting) -> String {
        guard let start = meeting.scheduledStart else { return "Not scheduled" }
        var parts = [Format.timeOfDay(start)]
        if let length = Format.duration(from: start, to: meeting.scheduledEnd) { parts.append(length) }
        // The calendar's own name, which the row does not carry — an ad-hoc meeting has none, and
        // leaving the part out is more honest than inventing one.
        if let name = model.calendarEvent(for: meeting)?.calendarName, !name.isEmpty {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    /// A folder is a real place to start a meeting — the new row is filed there. Needs write-up and
    /// Unfiled are views onto other lists, so offering to start one there would be a lie about
    /// where it would land.
    private var canStartHere: Bool {
        model.scope == .all || model.scope.folderID != nil
    }

    private var emptyTitle: String {
        switch model.scope {
        case .needsWriteUp: "No meetings waiting"
        case .unfiled: "No unfiled meetings"
        case .folder: "This folder is empty"
        default: "No meetings yet"
        }
    }

    private var emptyMessage: String {
        switch model.scope {
        case .needsWriteUp:
            "All transcribed meetings have been written up."
        case .unfiled:
            "Unfiled meetings collect here."
        case .folder:
            "Drag a meeting onto this folder to file it here."
        default:
            "Start a meeting and it appears here."
        }
    }
}

/// Title plus exactly one line of metadata. A second line of detail is what turns a scannable list
/// into a wall.
///
/// `incomplete` adds the caution mark beside the title — no extra line, so the row keeps its shape.
private struct MeetingRow: View {
    let title: String
    let metadata: String
    var incomplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if incomplete { TranscriptIssueMark() }
            }
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

extension View {
    /// The legend under a list that has at least one marked row, and nothing at all under one that
    /// does not — the same rule `meetings list` follows for its `*` line.
    @ViewBuilder
    func transcriptIssueLegend(shownWhen shown: Bool) -> some View {
        if shown {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    TranscriptIssueLegend()
                }
            }
        } else {
            self
        }
    }
}

/// Day headers here are large and bold and sit on the list background, matching macOS 26 Notes —
/// unlike sidebar section headers, which are small and quiet.
private struct DayHeader: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// What a pane shows while it is still reading. Deliberately *not* an empty state: "No meetings
/// yet" over a store that has meetings in it is a false statement about the user's data, and on a
/// large store it was on screen for twenty seconds.
struct LoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Every empty state says something true about why it is empty, and offers the one action that
/// would fill it when there is one.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            // A text style, not a point size: at Dynamic Type's larger settings a hard 28 pt glyph
            // sits next to text twice its size.
            Image(systemName: symbol)
                .font(.largeTitle)
                .fontWeight(.light)
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
