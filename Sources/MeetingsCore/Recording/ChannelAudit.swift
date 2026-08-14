import AVFoundation
import Foundation

/// What one channel's WAV actually contains, read off the file rather than remembered.
///
/// Read from disk on purpose. The in-memory peak the meters carry is only available in the process
/// that did the recording, and the two callers here are the stop path *and* the crash-recovery
/// sweep, where that process is gone. One rule, one implementation, and the file is the authority
/// either way.
public struct ChannelAudit: Sendable, Equatable {
    public let frames: Int64
    public let sampleRate: Double
    /// Every sample in the file is bit-exact zero.
    public let isDigitalSilence: Bool

    public var isEmpty: Bool { frames <= 0 }

    public var durationMs: Int {
        guard sampleRate > 0, frames > 0 else { return 0 }
        return Int((Double(frames) / sampleRate * 1000).rounded())
    }

    /// **The line between "nobody spoke" and "the device delivered zeros."**
    ///
    /// A real analog input never returns bit-exact zeros. Preamp noise, ADC dither and the room
    /// itself put a floor of at least a bit or two on every sample, so even a muted room recorded
    /// through a working microphone comes back with a non-zero peak within a few frames. A solid
    /// second in which not one sample differs from zero is not a quiet room; it is a device handing
    /// the tap a zero-filled buffer — which is exactly what macOS delivers when microphone access is
    /// denied, and what the `AUVPAggregate` defect ``MicRecorder`` already guards against delivers
    /// too. That guard draws the same line (`livenessPeak == 0` over the first second); this is the
    /// whole-file version of it, so the two cannot disagree.
    ///
    /// Deliberately an exact-zero test rather than a threshold. Any threshold above zero starts
    /// accusing a genuinely quiet meeting of a hardware fault, and a false "your voice was not
    /// recorded" on a meeting that recorded fine is worse than the silence it was meant to catch.
    /// The cost of drawing it here is that a mic delivering a constant non-zero DC offset — a
    /// different fault — reads as fine; nothing about the audio distinguishes that from a hum.
    public var deliveredNoSignal: Bool {
        sampleRate > 0 && Double(frames) >= sampleRate && isDigitalSilence
    }

    /// Nil when the file is absent or is not audio this machine can open.
    ///
    /// Cheap in the case that matters. The scan stops at the first non-zero sample, which on a
    /// working channel is inside the first buffer, so a healthy two-hour meeting costs one read.
    /// Only a file that really is silent all the way through is read end to end, and that is the
    /// case worth being certain about.
    public static func read(_ url: URL) -> ChannelAudit? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = file.length
        let rate = file.fileFormat.sampleRate
        guard frames > 0 else {
            return ChannelAudit(frames: 0, sampleRate: rate, isDigitalSilence: true)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            // Cannot inspect it, so do not claim it is silent — an unreadable buffer format is not
            // evidence of a dead microphone.
            return ChannelAudit(frames: frames, sampleRate: rate, isDigitalSilence: false)
        }

        var silent = true
        scan: while file.framePosition < frames {
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for index in 0..<Int(buffer.frameLength) where samples[index] != 0 {
                    silent = false
                    break scan
                }
            }
        }
        return ChannelAudit(frames: frames, sampleRate: rate, isDigitalSilence: silent)
    }

    /// The sentence a human reads when their own voice never made it in. Written once here because
    /// two paths raise it — the ordinary stop and the crash-recovery sweep — and a user must not be
    /// told two different things about the same fault.
    public static func noSignalReason(_ channel: Channel) -> String {
        switch channel {
        case .mic:
            return "the microphone delivered pure digital silence for the whole recording, so your "
                + "own voice was not captured. Nothing in this transcript is your half of the "
                + "meeting. The usual cause is Microphone access being off. Check Microphone under "
                + "Privacy & Security in System Settings before the next call."
        case .system:
            return "nothing at all came through the system-audio track, so no other participant "
                + "was recorded."
        }
    }

    public static func emptyReason(_ channel: Channel) -> String {
        "the recording ended before any audio reached the \(channel.rawValue) track, so there is "
            + "nothing on it to transcribe."
    }
}
