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
