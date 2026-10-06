// Records one window to a ProRes 4444 movie with a transparent background.
//
//   wincap --bundle-id com.yoelgal.meetings-film --out /tmp/shot.mov --seconds 12
//   wincap --window-id 141869 --out /tmp/shot.mov --seconds 12 --fps 60
//
// Why this exists rather than `screencapture -v`: on macOS 26 the video half of `screencapture`
// takes a display or an `-R` rect and has no fps, codec or cursor-exclusion flag at all — `-l
// <windowid>` is a still-image path. A launch film needs a *window*, at 60 fps, with no pointer in
// it, and with the window's own rounded corners cut out as alpha so the composition can float it
// over its own backdrop instead of over a rectangle of somebody's desktop.
//
// Every one of those is a documented SCK/AVFoundation knob, so this is configuration rather than
// cleverness:
//
//   SCContentFilter(desktopIndependentWindow:)   just that window, nothing behind it
//   showsCursor = false                          no pointer
//   backgroundColor = .clear + !shouldBeOpaque   straight alpha outside the window's corners
//   ignoreShadowsSingleWindow                    no shadow baked in; the film draws its own
//   minimumFrameInterval 1/fps                   a real frame rate
//   AVVideoCodecType.proRes4444                  the only ProRes profile that keeps the alpha
//
// It never activates, raises, moves, resizes or focuses anything: the operator is using this Mac.
// Like `scripts/shot.sh`, it reads the window server's backing store, so an unfocused or occluded
// window records fine.
import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

// MARK: - Recorder

/// Frames arrive on `queue` and are appended there; nothing else touches the writer.
final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "wincap.frames")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?

    /// The presentation timestamp the first kept frame defines as zero.
    private var origin: CMTime?
    private var keptFrames = 0
    private var droppedFrames = 0
    /// Frames before this instant are thrown away — see `--settle`.
    private let openShutterAt: Date
    private var streamError: Error?

    init(url: URL, width: Int, height: Int, alpha: Bool, settle: Double) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // ProRes 4444 rather than 422 HQ: 4444 is the only profile with an alpha channel, and the
        // alpha is the point — it is what lets the film composite the window's real rounded corners
        // over its own backdrop instead of over a rectangle of desktop.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // Frames come from the window server whenever the window redraws, not on the timeline's
        // cadence, so the timestamps are real presentation times rather than a frame counter.
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw WinCapError("AVAssetWriter refused a ProRes 4444 \(width)x\(height) input")
        }
        writer.add(input)
        openShutterAt = Date().addingTimeInterval(settle)
        _ = alpha  // the pixel format decides this; recorded here only so the caller's intent is legible
        super.init()
    }

    func start(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        guard writer.startWriting() else {
            throw writer.error ?? WinCapError("the writer would not start")
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // `of type:` — not `ofType:`. The protocol method is optional, so the wrong selector
        // compiles cleanly and gives you a stream that starts, reports no error, and delivers
        // nothing. The repo's audio path learned this; it is the same trap here.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func finish() async -> (kept: Int, dropped: Int, error: Error?) {
        if let stream { try? await stream.stopCapture() }
        // On the frame queue and after `stopCapture` returns, so no handler is still appending into
        // an input we are about to mark finished.
        queue.sync {}
        input.markAsFinished()
        await writer.finishWriting()
        return queue.sync {
            (keptFrames, droppedFrames, streamError ?? (writer.status == .failed ? writer.error : nil))
        }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // SCK sends a buffer per composite, including ones with no new pixels in them. A frame whose
        // status is `.complete` is the only kind carrying an image; appending the others writes
        // empty frames and desynchronises every timestamp after them.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }

        // Throw away the first moments. Attaching a stream makes the window server recomposite the
        // window, and those frames can carry the transition; a film that opens on one has a flash in
        // it that no amount of grading hides.
        guard Date() >= openShutterAt else { return }

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if origin == nil {
            origin = presentation
            writer.startSession(atSourceTime: .zero)
        }
        guard let origin else { return }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        // Retimed to start at zero rather than at the machine's uptime, so the movie a compositor
        // opens begins at 00:00 instead of somewhere three weeks in.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTimeSubtract(presentation, origin),
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed
        ) == noErr, let retimed else {
            droppedFrames += 1
            return
        }
        if input.append(retimed) { keptFrames += 1 } else { droppedFrames += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.sync { streamError = error }
    }
}

struct WinCapError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Entry point

@main
enum WinCap {
    static func log(_ line: String) {
        FileHandle.standardError.write(Data("wincap: \(line)\n".utf8))
    }

    static func die(_ message: String) -> Never {
        log(message)
        exit(1)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
            usage: wincap --out <file.mov> (--bundle-id <id> | --window-id <n>)
                          [--seconds <n>] [--fps <n>] [--opaque] [--settle <seconds>]

              --seconds   how long to record; default 10
              --fps       default 60
              --opaque    keep the window's own backdrop instead of cutting alpha outside its corners
              --settle    discard frames for this long after the stream starts, so the recomposite
                          SCK triggers on attach never reaches the film. Default 0.4

            """.utf8))
        exit(64)
    }

    /// The same rule `scripts/shot.sh` uses, and for the same reason: a process owns panels,
    /// popovers and the occasional zero-size helper, and the one worth filming is the biggest normal
    /// window it has. `.optionAll` rather than `.optionOnScreenOnly` because a backgrounded window
    /// drops off the on-screen list while staying perfectly capturable.
    static func largestWindowID(bundleID: String) -> CGWindowID? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var best: (id: CGWindowID, area: Double)?
        for window in infos {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= 200, height >= 200
            else { continue }
            if best == nil || width * height > best!.area { best = (id, width * height) }
        }
        return best?.id
    }

    static func main() async {
        // Connect to the window server before touching CoreGraphics or ScreenCaptureKit.
        //
        // This is a plain command line tool, not an app bundle, so nothing has set that connection
        // up — and the first CG call in an uninitialised process aborts on
        // `Assertion failed: (did_initialize), function CGS_REQUIRE_INIT`. It only showed up once
        // `--window-id` existed: the `--bundle-id` path calls `NSRunningApplication`, which
        // initialises AppKit as a side effect, so passing a window id skipped the one thing that was
        // accidentally doing this.
        //
        // `.prohibited` is not tidiness. Touching `NSApplication.shared` makes this process an app as
        // far as the window server is concerned, and the default policy would give a recorder its own
        // Dock tile and let it be activated — during a shoot, in front of the window it is filming.
        NSApplication.shared.setActivationPolicy(.prohibited)

        var options: [String: String] = [:]
        var flags: Set<String> = []
        var argv = Array(CommandLine.arguments.dropFirst())
        while let arg = argv.first {
            argv.removeFirst()
            guard arg.hasPrefix("--") else { usage() }
            let key = String(arg.dropFirst(2))
            if key == "opaque" { flags.insert(key); continue }
            guard let value = argv.first else { usage() }
            argv.removeFirst()
            options[key] = value
        }

        guard let outPath = options["out"] else { usage() }
        guard let seconds = Double(options["seconds"] ?? "10"), seconds > 0,
              let fps = Int32(options["fps"] ?? "60"), fps > 0,
              let settle = Double(options["settle"] ?? "0.4"), settle >= 0
        else { usage() }
        let wantsAlpha = !flags.contains("opaque")

        // A silent check. `SCShareableContent` *prompts* when the state is notDetermined, which would
        // put a permission dialog on screen in the middle of a shoot.
        guard CGPreflightScreenCaptureAccess() else {
            die("no Screen Recording permission. Grant it to the terminal running this, in System "
                + "Settings › Privacy & Security › Screen & System Audio Recording.")
        }

        let targetWindowID: CGWindowID
        if let raw = options["window-id"], let id = CGWindowID(raw) {
            targetWindowID = id
        } else if let bundleID = options["bundle-id"] {
            guard let id = largestWindowID(bundleID: bundleID) else {
                die("no capturable window for \(bundleID) — is it running?")
            }
            targetWindowID = id
        } else {
            usage()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            die("could not read the window list: \(error)")
        }
        guard let window = content.windows.first(where: { $0.windowID == targetWindowID }) else {
            die("window \(targetWindowID) is not in SCShareableContent — it may have closed")
        }

        // `desktopIndependentWindow` is what makes this a window recording rather than a crop of the
        // screen: SCK composites that window alone, at its own size, with nothing behind it.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        // Native Retina pixels. `contentRect` is in points and `pointPixelScale` is the display's
        // factor, so their product is the backing store's real size; asking for the point size would
        // film a 2x window at 1x and throw away half the resolution the text is drawn at.
        let scale = CGFloat(filter.pointPixelScale)
        let pixelWidth = Int((filter.contentRect.width * scale).rounded())
        let pixelHeight = Int((filter.contentRect.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { die("the window has no size to record") }
        config.width = pixelWidth
        config.height = pixelHeight
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 8
        config.showsCursor = false
        config.capturesAudio = false
        // No shadow, and no clip to the display's edges: the film draws its own shadow, and a window
        // near a screen edge must not come back with a straight cut down one side of it.
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        if wantsAlpha {
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.backgroundColor = .clear
            config.shouldBeOpaque = false
        }

        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let recorder: WindowRecorder
        do {
            recorder = try WindowRecorder(
                url: url, width: pixelWidth, height: pixelHeight, alpha: wantsAlpha, settle: settle)
            try await recorder.start(filter: filter, config: config)
        } catch {
            die("could not start the capture: \(error)")
        }

        let points = "\(Int(filter.contentRect.width))x\(Int(filter.contentRect.height))pt"
        log("recording window \(targetWindowID) at \(pixelWidth)x\(pixelHeight) "
            + "(\(points) @\(Int(scale))x), \(fps)fps, \(seconds)s"
            + (wantsAlpha ? ", alpha" : ""))

        try? await Task.sleep(for: .seconds(seconds + settle))
        let result = await recorder.finish()
        if let error = result.error { die("capture failed: \(error)") }
        guard result.kept > 0 else { die("no frames were captured") }
        log("\(result.kept) frames kept, \(result.dropped) dropped")
        print(outPath)
    }
}
