import Foundation
import MeetingsCore
import Testing

@testable import MeetingsApp

/// **The last sentence before a file leaves this Mac.** The import sheet says where the audio is
/// transcribed, immediately above the Import button, and with the remote engine configured nothing
/// else on that screen warns — `Prerequisites.forTranscription` is empty by design, because there is
/// nothing to download. So a claim of "transcribed on this Mac" beside a button that uploads is the
/// one sentence in this app that must not be wrong.
///
/// Behavioural rather than a scan of `AudioImport.swift` for the phrase: the phrase is *correct* on
/// the local engine and only wrong when it is unconditional, which a substring search cannot tell
/// apart. Asking the function both questions can.
@Suite struct ImportSheetWordingTests {
    @Test func theCloudEngineNeverClaimsTheAudioStaysOnThisMac() {
        let cloud = ImportSheet.whereItIsTranscribed(.cloud)
        #expect(!cloud.contains("transcribed on this Mac"), """
            The import sheet tells a cloud user their audio is transcribed locally, with the file \
            about to be uploaded: "\(cloud)"
            """)
        #expect(cloud.contains("uploaded"), "it has to say plainly that the recording leaves the Mac")
        #expect(cloud.contains("leaves it"), "…and that this is the recording itself, not a summary")
    }

    /// And the other half, or "never claims this Mac" would be satisfied by saying nothing at all.
    @Test func theLocalEngineSaysTheAudioStaysHere() {
        let local = ImportSheet.whereItIsTranscribed(.local)
        #expect(local.contains("transcribed on this Mac"))
        #expect(!local.contains("uploaded"), "nothing is uploaded on the local engine")
    }

    /// Every engine the app can be in answers something, so a new tier cannot ship a blank sentence
    /// where the upload warning goes.
    @Test func everyEngineChoiceSaysSomething() {
        for engine in TranscriptionEngineChoice.allCases {
            #expect(!ImportSheet.whereItIsTranscribed(engine).isEmpty, "\(engine) says nothing")
        }
    }
}
