import Foundation
import MeetingsCore

// The demo store the Loom-style demo is shot against.
//
// Everything is invented. The people, the company, the meetings and every line of dialogue are made
// up, and every address is under `example.com` / `.example`, which RFC 2606 reserves precisely so a
// fixture can never name a real mailbox.
//
// It is all written through `MeetingStore`, so the search index, the note anchors and the `- [ ]` task
// items are real: `meetings search "pricing"` finds what the demo shows it finding, and the checkbox
// on screen is the same markdown line the app ticks. A fixture built by hand-writing SQL would
// photograph a store the app cannot produce.
//
// It never touches the operator's own meetings: `MEETINGS_HOME` points somewhere under /tmp, and
// `Paths` rejects a relative one, so there is no path where this writes to the real store by accident.
//
//   seed                     the whole demo store; prints the refs as JSON
//   seed live                a meeting that is recording right now; prints its ref
//   seed say <ref> <ms> <channel> <text>
//                            append one live transcript segment, as the recogniser would
//
// `say` exists because the CLI has no verb for it, on purpose — nothing but the transcriber writes
// live segments in normal use. It is how the film animates the live transcript without touching the
// keyboard: each call commits and posts a `StoreChange`, and the open window redraws itself.

let store = MeetingStore(dbPool: try MeetingsDatabase.open())
let minute = 60.0
let args = Array(CommandLine.arguments.dropFirst())

/// Rounded down to the minute so a re-shoot of one scene matches the take before it.
let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / minute).rounded(.down) * minute)

/// `days` from today at a named wall-clock time.
///
/// Everything dated off `now + n * 86400` lands at whatever o'clock the shoot happened to start, so
/// a take at 16:34 put "Thursday standup" at 02:04 — a time no standup has ever been held at, and
/// the sort of detail that makes a demo look staged. A meeting happens at a time somebody chose, so
/// the fixture chooses one.
func at(_ days: Int, _ hour: Int, _ minutes: Int = 0) -> Date {
    let calendar = Calendar.current
    let midnight = calendar.startOfDay(for: now.addingTimeInterval(Double(days) * 86_400))
    return calendar.date(byAdding: DateComponents(hour: hour, minute: minutes), to: midnight)!
}

/// "Monday", "Thursday"… for a date. A meeting named after its weekday has to be named *from* its
/// date: hard-coded, a shoot on a Monday filed "Monday standup" on Sunday.
func weekday(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
}

/// The nearest working day `days` from today, stepping further out (in the direction of `days`) past
/// a weekend. Standups are held on weekdays; named from their date, a weekend one reads as staged.
func workday(_ days: Int) -> Int {
    var day = days
    let step = days < 0 ? -1 : 1
    while Calendar.current.isDateInWeekend(at(day, 12)) { day += step }
    return day
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("seed: \(message)\n".utf8))
    exit(64)
}

// MARK: - seed say <ref> <offsetMs> <mic|system> <text>

if args.first == "say" {
    guard args.count == 5, let offset = Int(args[2]), let channel = Channel(rawValue: args[3]) else {
        fail("usage: seed say <ref> <offsetMs> <mic|system> <text>")
    }
    let segment = try store.insertSegment(TranscriptSegment(
        meetingID: args[1],
        channel: channel,
        tStartMs: offset,
        // Live text is on screen before the phrase has finished, so a live row's end is where the
        // words got to, not where the sentence will end.
        tEndMs: offset + 2_600,
        text: args[4],
        pass: .live
    ))
    print(segment.id ?? -1)
    exit(0)
}

// MARK: - seed live / seed keepalive <ref>

// A meeting that is recording *right now*. Created on demand rather than with everything else
// because it is the newest row in the store and would reorder every listing the other scenes frame.
//
// Started 4m12s ago on purpose: the transport draws a running clock, and a clock reading 00:03
// undercuts the shot by making the app look like it was launched for the camera.
//
// The two WAVs are not decoration. `RecordingRecovery` sweeps every `recording` row the running
// process does not own and moves it somewhere true — which is exactly right, because that row is
// normally the remains of a crash. Its liveness test is whether a `.wav` in the meeting's audio
// directory was written inside the last fifteen seconds, so a row with no audio behind it is
// recovered within a second of launch: the first take of this shot came back reading "Needs
// write-up" with a "one side of that conversation is missing" warning on it, which is the app
// being right.
//
// So the audio is real and `keepalive` keeps appending to it for as long as the shot runs. Nothing
// is faked: while those files are growing there *is* a capture in progress as far as any reader can
// tell, and the window is correct to draw a recording.
func liveAudioDirectory(_ meetingID: String) -> URL {
    Paths.audioRoot.appendingPathComponent(meetingID, isDirectory: true)
}

/// A 48 kHz mono 16-bit WAV header with `frames` of silence after it. The same shape
/// ``ChannelWriter`` produces, so anything that reads one of these reads a valid file.
func silentWAV(frames: Int) -> Data {
    let channels = 1, rate = 48_000, bits = 16
    let dataBytes = frames * channels * bits / 8
    var wav = Data()
    func ascii(_ s: String) { wav.append(contentsOf: s.utf8) }
    func u32(_ v: Int) { wav.append(contentsOf: withUnsafeBytes(of: UInt32(v).littleEndian, Array.init)) }
    func u16(_ v: Int) { wav.append(contentsOf: withUnsafeBytes(of: UInt16(v).littleEndian, Array.init)) }
    ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(channels); u32(rate)
    u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
    ascii("data"); u32(dataBytes)
    wav.append(Data(count: dataBytes))
    return wav
}

if args.first == "live" {
    let live = try store.createMeeting(Meeting(
        title: "Catch-up with Marcus",
        state: .recording,
        startedAt: now.addingTimeInterval(-252),
        attendees: [Attendee(name: "Marcus Ell", email: "marcus@example.com")]
    ))
    let directory = liveAudioDirectory(live.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for channel in Channel.allCases {
        try silentWAV(frames: 252 * 48_000)
            .write(to: directory.appendingPathComponent("\(channel.rawValue).wav"))
    }
    print(live.id)
    exit(0)
}

// Appends a tenth of a second of audio to both tracks, which is what makes the row read as live.
// Called on a timer by `video/shoot.sh` for the length of a recording shot.
// MARK: - seed drop <ref>
//
// The live meeting, gone once its shots are taken. `meetings delete` refuses a meeting at
// `recording`, by design; the fixture is the one writer that may end a recording nobody is making,
// and leaving it in the list put "Catch-up with Marcus · Recording" into every later shot.
if args.first == "drop" {
    guard args.count == 2 else { fail("usage: seed drop <ref>") }
    // The store refuses to delete a meeting at `recording` (audio may still be going into it), so
    // the fixture closes it first — it knows nothing is.
    try store.updateMeeting(id: args[1]) { $0.state = .complete }
    _ = try store.deleteMeeting(id: args[1])
    exit(0)
}

if args.first == "keepalive" {
    guard args.count == 2 else { fail("usage: seed keepalive <ref>") }
    let directory = liveAudioDirectory(args[1])
    for channel in Channel.allCases {
        let url = directory.appendingPathComponent("\(channel.rawValue).wav")
        guard let handle = try? FileHandle(forWritingTo: url) else {
            fail("no track at \(url.path) — run `seed live` first")
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 4_800 * 2))
        try handle.close()
    }
    exit(0)
}

guard args.isEmpty else { fail("unknown argument \(args[0])") }

// MARK: - Settings

try store.setSetting(.onboardingCompleted, "true")

// MARK: - Folders

let product = try store.createFolder(Folder(name: "Product"))
let clients = try store.createFolder(Folder(name: "Clients"))

// The words the recogniser would otherwise mangle. On screen this is the Vocabulary pane; in the
// transcript it is why the client's name comes through spelled the same way every time.
for term in ["Northwind", "Halloway", "onboarding funnel", "seat-based"] {
    _ = try? store.addVocabularyTerm(VocabularyTerm(term: term, folderID: product.id, source: .manual))
}

// MARK: - 1. The finished meeting, written up

// The demo's centre of gravity: a real-looking write-up with real-looking actions under it.
let syncStart = at(-2, 10)
let sync = try store.createMeeting(Meeting(
    folderID: product.id,
    title: "Weekly product sync",
    state: .complete,
    startedAt: syncStart,
    endedAt: syncStart.addingTimeInterval(28 * minute),
    attendees: [
        Attendee(name: "Dana Whitfield", email: "dana@example.com"),
        Attendee(name: "Marcus Ell", email: "marcus@example.com"),
    ],
    preNotes: """
        Three things: what we do about the trial drop-off, whether pricing goes seat-based, and who \
        owns the Northwind kickoff.
        """,
    summary: """
        ## What we decided

        - Trials drop off at the workspace-invite step, not at signup. That step becomes optional and moves to the end of onboarding.
        - Pricing goes seat-based in the new year, not this quarter. Changing it a fortnight before the Northwind kickoff helps nobody.
        - Dana owns the Northwind kickoff and Marcus writes the migration note that goes out with it.

        ## Actions

        - [x] Pull the funnel numbers for the invite step
        - [ ] Dana: make the workspace invite optional
        - [ ] Marcus: draft the migration note for Northwind
        - [ ] Dana: book the kickoff for Thursday

        ## Open questions

        - Whether seat-based pricing needs a grandfather clause. Nobody wanted to guess before we have seen a month of the new funnel.

        ## Not covered

        - Nothing. All three agenda points were discussed.
        """
))

/// Alternating channels. `.mic` is the user and `.system` is everyone else — channel separation is
/// the only speaker attribution there is, and the demo shows exactly that.
let dialogue: [(Channel, String)] = [
    (.mic, "Right, three things. Trial drop-off, pricing, and who owns the Northwind kickoff."),
    (.system, "Dana here. The drop-off is not at signup, it is at the invite-your-workspace step."),
    (.mic, "How much are we losing there?"),
    (.system, "Dana: about a third of everyone who signs up never gets past it."),
    (.mic, "A third. That step is asking people to do admin before they have seen anything work."),
    (.system, "Marcus here — agreed, and it is the only screen in onboarding that needs somebody else."),
    (.mic, "Then make it optional and move it to the end."),
    (.system, "Dana: I can have that behind a flag this week."),
    (.mic, "Second thing. Do we go seat-based this quarter?"),
    (.system, "Marcus: I would not. The Northwind kickoff is in a fortnight and they priced on the current plan."),
    (.mic, "Changing the pricing page two weeks before a kickoff is how you lose the kickoff."),
    (.system, "Dana: new year then, with a proper migration note rather than a changelog line."),
    (.mic, "Marcus, can you draft that note?"),
    (.system, "Marcus: yes. I will keep it to one page and say what happens to existing plans."),
    (.mic, "Last thing — who owns the kickoff?"),
    (.system, "Dana: I will take it. Thursday works if their team can do the morning."),
    (.mic, "Book it. And send the migration note with the invite, not after it."),
    (.system, "Dana: understood."),
]

_ = try store.insertSegments(dialogue.enumerated().map { index, line in
    TranscriptSegment(
        meetingID: sync.id,
        channel: line.0,
        tStartMs: index * 92_000,
        tEndMs: index * 92_000 + 8_000,
        text: line.1,
        pass: .final
    )
})

for note in [
    (4 * 60_000 + 40_000, "Invite step is the drop-off. Make it optional."),
    (13 * 60_000 + 30_000, "Seat-based in the new year, not this quarter."),
    (21 * 60_000 + 10_000, "Migration note ships with the invite, not after."),
] {
    _ = try store.addNote(meetingID: sync.id, tOffsetMs: note.0, text: note.1)
}

// MARK: - 2. The meeting the transcript and notes beats are shot on

// Deliberately the shortest write-up in the store with the longest dialogue under it, so an opened
// transcript and its notes are both on screen at once. The three collapsible sections sit *below* the
// write-up and the display tops out at 948 points, so on the sync — whose write-up runs four sections
// — an opened transcript is off the bottom of the window and cannot be photographed at all.
let callStart = at(-4, 15, 30)
let call = try store.createMeeting(Meeting(
    folderID: clients.id,
    title: "Northwind onboarding call",
    state: .complete,
    startedAt: callStart,
    endedAt: callStart.addingTimeInterval(21 * minute),
    attendees: [
        Attendee(name: "Dana Whitfield", email: "dana@example.com"),
        Attendee(name: "Ivy Cho", email: "ivy@northwind.example"),
    ],
    summary: """
        ## What we decided

        - Northwind moves 40 seats over on the current plan, and pricing is revisited in the new year.

        ## Actions

        - [x] Ivy: send the seat list as a CSV
        - [ ] Dana: set their workspace up before Thursday
        """
))

let callDialogue: [(Channel, String)] = [
    (.system, "Ivy here. Forty seats to start, and I should say we have people on two different tools today."),
    (.mic, "Forty is fine. The two tools part is the bit that takes the time, not the seats."),
    (.system, "Ivy: is there an import, or is it copy and paste?"),
    (.mic, "There is an import. Send me the seat list as a CSV and I will have the workspace ready."),
    (.system, "Ivy: and pricing — are we on the current plan or the new one?"),
    (.mic, "Current plan. Anything we change lands in the new year with a note explaining it."),
    (.system, "Ivy: good. That is the answer I needed for my finance team."),
    (.mic, "I will put it in writing so you can forward it rather than quote me."),
]
_ = try store.insertSegments(callDialogue.enumerated().map { index, line in
    TranscriptSegment(
        meetingID: call.id,
        channel: line.0,
        tStartMs: index * 105_000,
        tEndMs: index * 105_000 + 9_000,
        text: line.1,
        pass: .final
    )
})

// Each offset lands inside the line that prompted it, so clicking a note scrolls to the sentence
// underneath it — which is the claim, and it is checkable against the dialogue above.
for note in [
    (120_000, "Two existing tools is the work, not the seat count."),
    (330_000, "CSV import, then set the workspace up for them."),
    (530_000, "Current plan. Pricing note in the new year."),
    (720_000, "Put the pricing answer in writing for their finance team."),
] {
    _ = try store.addNote(meetingID: call.id, tOffsetMs: note.0, text: note.1)
}

// MARK: - 3. Two meetings waiting to be written up

// The sidebar's write-up queue is the only thing that remembers, so the demo shows it holding two and
// then holding one. Oldest first is how the queue sorts, so this is the one at the top of it.
let reviewStart = at(-5, 11, 30)
let review = try store.createMeeting(Meeting(
    folderID: product.id,
    title: "Design review",
    state: .ready,
    startedAt: reviewStart,
    endedAt: reviewStart.addingTimeInterval(16 * minute),
    attendees: [Attendee(name: "Ravi Menon", email: "ravi@example.com")]
))
_ = try store.insertSegments([
    TranscriptSegment(meetingID: review.id, channel: .mic, tStartMs: 0, tEndMs: 7_000,
                      text: "Where did the empty state end up?", pass: .final),
    TranscriptSegment(meetingID: review.id, channel: .system, tStartMs: 8_000, tEndMs: 20_000,
                      text: "Ravi: it says what to do next now, rather than telling you the list is empty.",
                      pass: .final),
])

let standupStart = at(workday(-1), 9, 15)
let standup = try store.createMeeting(Meeting(
    folderID: product.id,
    title: "\(weekday(standupStart)) standup",
    state: .ready,
    startedAt: standupStart,
    endedAt: standupStart.addingTimeInterval(11 * minute),
    attendees: [Attendee(name: "Marcus Ell", email: "marcus@example.com")]
))
_ = try store.insertSegments([
    TranscriptSegment(meetingID: standup.id, channel: .mic, tStartMs: 0, tEndMs: 6_000,
                      text: "Quick one. Anything blocked?", pass: .final),
    TranscriptSegment(meetingID: standup.id, channel: .system, tStartMs: 7_000, tEndMs: 19_000,
                      text: "Marcus: the migration note, I am waiting on the final pricing wording.",
                      pass: .final),
    TranscriptSegment(meetingID: standup.id, channel: .mic, tStartMs: 20_000, tEndMs: 28_000,
                      text: "You will have it today. Send the note with the invite.", pass: .final),
])
_ = try store.addNote(meetingID: standup.id, tOffsetMs: 21_000, text: "Get Marcus the pricing wording today.")

// MARK: - 4. Tomorrow, with the notes already written against it

let kickoffEventID = "EV-northwind-kickoff"
let kickoffStart = at(1, 10)
let kickoff = try store.createMeeting(Meeting(
    folderID: clients.id,
    title: "Northwind kickoff",
    state: .scheduled,
    calendarEventID: kickoffEventID,
    scheduledStart: kickoffStart,
    scheduledEnd: kickoffStart.addingTimeInterval(45 * minute),
    attendees: [
        Attendee(name: "Dana Whitfield", email: "dana@example.com"),
        Attendee(name: "Ivy Cho", email: "ivy@northwind.example"),
    ],
    preNotes: """
        - Walk them through the workspace we set up, not a slide about it.
        - Send the migration note with the invite.
        - Do not promise a date for seat-based pricing.
        """
))

// MARK: - The calendar the window reads

// A fixture rather than Apple Calendar: the demo must not need the operator's calendar permission, and
// must not put anything in the operator's calendar either.
let events = [
    CalendarEvent(
        id: kickoffEventID, title: "Northwind kickoff",
        start: kickoffStart, end: kickoffStart.addingTimeInterval(45 * minute),
        attendees: [Attendee(name: "Dana Whitfield", email: "dana@example.com"),
                    Attendee(name: "Ivy Cho", email: "ivy@northwind.example")],
        calendarName: "Work", videoLink: URL(string: "https://zoom.us/j/98123456789"),
        notes: "Kickoff. Ivy asked to see the workspace rather than slides."
    ),
    CalendarEvent(
        id: "EV-standup-thu", title: "\(weekday(at(workday(2), 9, 15))) standup",
        start: at(workday(2), 9, 15), end: at(workday(2), 9, 30),
        attendees: [Attendee(name: "Marcus Ell", email: "marcus@example.com")],
        calendarName: "Work", videoLink: URL(string: "https://meet.google.com/abc-defg-hij"), notes: nil
    ),
    CalendarEvent(
        id: "EV-pricing", title: "Pricing working group",
        start: at(3, 14), end: at(3, 14, 45),
        attendees: [Attendee(name: "Dana Whitfield", email: "dana@example.com"),
                    Attendee(name: "Ravi Menon", email: "ravi@example.com")],
        calendarName: "Work", videoLink: URL(string: "https://meet.goto.com/pricing"),
        notes: "Seat-based, and what happens to existing plans."
    ),
    // Not a meeting: no link, nobody to call. It is inside every window Upcoming looks at and must
    // still never appear there — it is in the fixture precisely so the demo cannot accidentally show a
    // birthday in a list of meetings.
    CalendarEvent(
        id: "EV-birthday", title: "Halloway's birthday",
        start: at(1, 0), end: at(2, 0),
        attendees: [], calendarName: "Personal", videoLink: nil, notes: nil
    ),
]

guard let fixturePath = ProcessInfo.processInfo.environment["MEETINGS_CALENDAR_FIXTURE"] else {
    fail("MEETINGS_CALENDAR_FIXTURE is not set, so Upcoming would be empty")
}
let calendar = JSONEncoder()
calendar.dateEncodingStrategy = .iso8601
calendar.outputFormatting = [.prettyPrinted]
try calendar.encode(events).write(to: URL(fileURLWithPath: fixturePath))

// MARK: - The refs the shoot script drives

struct Seeded: Encodable {
    let sync: String
    let call: String
    let review: String
    let standup: String
    let kickoff: String
    let productFolder: String
    let segments: Int
}
let out = JSONEncoder()
out.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try out.encode(Seeded(
    sync: sync.id,
    call: call.id,
    review: review.id,
    standup: standup.id,
    kickoff: kickoff.id,
    productFolder: product.id,
    segments: dialogue.count
)))
