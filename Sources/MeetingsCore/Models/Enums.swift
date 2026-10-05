import Foundation

/// The lifecycle. `scheduled` rows exist only for meetings you have actually touched —
/// a calendar event with no pre-notes renders straight from EventKit and has no row at all.
public enum MeetingState: String, Codable, Sendable, CaseIterable {
    case scheduled, recording, transcribing, ready, complete
}

/// Mic vs system audio. Channel separation *is* the speaker attribution mechanism in v1,
/// so this is not cosmetic metadata — it is the only thing telling you who said what.
public enum Channel: String, Codable, Sendable, CaseIterable {
    case mic, system
}

/// Which transcription pass produced a segment. `live` rows are approximate and get replaced
/// wholesale by the batch pass; `final` rows are authoritative.
public enum Pass: String, Codable, Sendable, CaseIterable {
    case live, final
}

public enum VocabSource: String, Codable, Sendable, CaseIterable {
    case manual, attendee, correction
}

public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    case recorded, imported
}

extension Channel {
    /// mic is whoever is sitting at this Mac; system is everything coming out of the speakers.
    ///
    /// The transcript is read by an agent asked things like "what did I commit to", so the label has
    /// to name the *speaker*, not the plumbing: `mic:` and `system:` describe where the audio came
    /// from and leave the agent to guess which one is the user.
    public var speakerLabel: String {
        switch self {
        case .mic: "You"
        case .system: "Others"
        }
    }
}
