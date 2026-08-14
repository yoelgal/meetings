import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// TEMPORARY attack harness — deleted before the unit lands. Runs only when MEETINGS_ATTACK_DIR is
/// set, so the ordinary suite never sees it.
@Suite("Attack scratch", .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_ATTACK_DIR"] != nil))
struct RobustAttackScratchTests {
    var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEETINGS_ATTACK_DIR"]!)
    }

    @Test("open a writer on a volume that is already full")
    func openOnFullVolume() throws {
        let url = root.appendingPathComponent("second.wav")
        do {
            let writer = try ChannelWriter(url: url, origin: Date())
            print("ATTACK open succeeded on a full volume")
            for _ in 0..<20 { writer.append(AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1)) }
            print("ATTACK framesWritten=\(writer.framesWritten) level=\(writer.level)")
            writer.finish()
            let audit = ChannelAudit.read(url)
            print("ATTACK audit frames=\(audit?.frames ?? -1) silent=\(audit?.isDigitalSilence ?? false)")
        } catch {
            print("ATTACK open failed: \(error)")
        }
    }

    @Test("fill the volume under a live writer", .disabled("run one at a time"))
    func diskFull() throws {
        let url = root.appendingPathComponent("mic.wav")
        try? FileManager.default.removeItem(at: url)
        let writer = try ChannelWriter(url: url, origin: Date())
        let chunk = AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1)
        var lastFrames: Int64 = 0
        for i in 0..<3000 {
            writer.append(chunk)
            if i % 200 == 0 {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? Int) ?? -1
                print("ATTACK i=\(i) framesWritten=\(writer.framesWritten) size=\(size ?? -1) "
                    + "level=\(writer.level)")
            }
            lastFrames = writer.framesWritten
        }
        print("ATTACK final framesWritten=\(lastFrames) level=\(writer.level)")
        writer.finish()
        let audit = ChannelAudit.read(url)
        print("ATTACK audit frames=\(audit?.frames ?? -1) durationMs=\(audit?.durationMs ?? -1)")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        print("ATTACK file size=\(size ?? -1)")
    }
}
