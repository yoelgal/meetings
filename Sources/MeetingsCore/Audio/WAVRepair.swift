import Foundation

/// A WAV that was never closed reads as **zero frames** even though every sample is on disk.
/// `AVAudioFile` flushes PCM on each `write(from:)` but only writes the RIFF and `data` chunk sizes
/// when it deallocates, so a crash mid-meeting leaves a file that looks empty to every reader
/// including our own batch pass. Recomputing the two size fields from the real file length brings
/// the whole recording back.
public enum WAVRepair {
    /// Rewrite a WAV's RIFF and `data` chunk sizes from its on-disk length. Idempotent — a healthy
    /// file gets the same values it already had.
    ///
    /// Returns whether anything was written. A file whose sizes already agree is left completely
    /// alone: writing the same eight bytes back and then `fsync`ing them is the whole cost of the
    /// launch sweep, and it was being paid once per WAV for the life of the store even though a
    /// crash leaves at most the one file that was open at the time.
    @discardableResult
    public static func repair(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 12 else { return false }

        // Walk the chunks. `AVAudioFile` emits a 28-byte JUNK chunk and a 4008-byte FLLR alignment
        // chunk before `data`, so the header is 4096 bytes and the size field we want sits at 4092.
        // Repair code that assumes the canonical 44-byte layout writes into the middle of the audio.
        var offset: UInt64 = 12
        var dataHeader: UInt64?
        var recordedDataSize: UInt32?
        while offset + 8 <= size {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let id = String(bytes: header.prefix(4), encoding: .ascii) ?? ""
            let chunkSize = header.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            if id == "data" {
                dataHeader = offset
                recordedDataSize = chunkSize
                break
            }
            offset += 8 + UInt64(chunkSize) + UInt64(chunkSize % 2)  // chunks are word-aligned
        }
        guard let dataHeader, let recordedDataSize else { return false }

        let payload = dataHeader + 8
        guard size >= payload else { return false }
        let dataSize = UInt32(size - payload)

        // Both fields, because a file can be wrong in either: the RIFF size is written last.
        try handle.seek(toOffset: 4)
        let recordedRiffSize = try handle.read(upToCount: 4).flatMap(Self.uint32)
        guard recordedDataSize != dataSize || recordedRiffSize != UInt32(size - 8) else { return false }

        try handle.seek(toOffset: dataHeader + 4)
        try handle.write(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: UInt32(size - 8).littleEndian) { Data($0) })
        try handle.synchronize()
        return true
    }

    private static func uint32(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    /// Sweep every recording directory at launch, before anything reads a WAV. Returns the files it
    /// actually **changed**, which on a healthy store is none. A file it cannot open is skipped
    /// rather than fatal — one unreadable meeting must not stop the app from starting.
    ///
    /// This is on the launch path because nothing may read a WAV before it has run, and it stays
    /// there: measured over a 60-meeting store (120 files, 223 MB) it costs 12 ms, against a cold
    /// launch of about 1 100 ms that is spent almost entirely in dyld and the first SwiftUI frame.
    /// The batch pass repairs the file it is about to read as well (``TranscriptionService``), so
    /// the guarantee does not rest on this sweep alone.
    @discardableResult
    public static func repairTree(at root: URL = Paths.audioRoot) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var repaired: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "wav" {
            if (try? repair(at: url)) == true { repaired.append(url) }
        }
        return repaired
    }
}
