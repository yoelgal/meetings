import Foundation

/// What this Mac is, as far as `sysctl` will say.
///
/// Used for exactly one thing: choosing which candidate `meetings fit` *starts* with, so it does not
/// have to download every model to find out. It is never the answer. The answer is what
/// ``FitRunner`` measured on this machine afterwards.
public struct MachineProfile: Sendable, Codable, Equatable {
    /// `machdep.cpu.brand_string`, e.g. "Apple M1 Pro".
    public let chip: String
    /// `hw.perflevel0.logicalcpu`. Zero on Intel, which has no perflevel split.
    public let performanceCores: Int
    /// `hw.perflevel1.logicalcpu`. Zero on a machine with no efficiency cores.
    public let efficiencyCores: Int
    public let memoryBytes: Int64
    public let osVersion: String

    public init(chip: String, performanceCores: Int, efficiencyCores: Int, memoryBytes: Int64, osVersion: String) {
        self.chip = chip
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.memoryBytes = memoryBytes
        self.osVersion = osVersion
    }

    public static func current() -> MachineProfile {
        MachineProfile(
            chip: string("machdep.cpu.brand_string") ?? "unknown",
            performanceCores: Int(integer("hw.perflevel0.logicalcpu") ?? 0),
            efficiencyCores: Int(integer("hw.perflevel1.logicalcpu") ?? 0),
            memoryBytes: integer("hw.memsize") ?? 0,
            // The components rather than `operatingSystemVersionString`, which reads "Version 26.1
            // (Build 25B78)" — the build number is noise in a sentence about whether a model runs.
            osVersion: {
                let version = ProcessInfo.processInfo.operatingSystemVersion
                return "macOS \(version.majorVersion).\(version.minorVersion)"
            }()
        )
    }

    public var memoryGB: Int { Int((Double(memoryBytes) / 1_073_741_824).rounded()) }

    /// Apple silicon has a Neural Engine; Intel does not, and every model here is a Core ML package
    /// built for one. Read off the brand string because there is no cheaper honest signal.
    public var isAppleSilicon: Bool { chip.hasPrefix("Apple ") }

    public var summary: String {
        let cores = performanceCores + efficiencyCores == 0
            ? ""
            : " · \(performanceCores)P/\(efficiencyCores)E cores"
        return "\(chip)\(cores) · \(memoryGB) GB · \(osVersion)"
    }

    // MARK: - Where to start

    /// The index in `candidates` that `fit` downloads and measures first.
    ///
    /// **This table is an extrapolation, and it is the only part of `fit` that is.** Exactly one
    /// machine has ever been measured — an M1 Pro, 54.5 s fixture, single channel — so anything said
    /// here about an M4 Max or an 8 GB M1 Air is inference from core count and memory, not data.
    /// That is tolerable only because nothing downstream trusts it: whatever this picks is then run
    /// on the actual machine and rejected if it misses the bar. Getting this wrong costs one wasted
    /// download, never a wrong answer.
    ///
    /// The two things it does encode are not guesses:
    ///
    ///   * A machine with no Neural Engine cannot run any of these usefully, so it starts at the
    ///     fallback and `fit` says why.
    ///   * The 0.6B live tiers hold roughly five times the weights of the 120M one and a meeting
    ///     runs *two* of them at once, so a machine below the measured one starts lower.
    ///
    /// The boundary is the measured machine itself — an M1 Pro reporting **6 performance cores, 2
    /// efficiency, 16 GB** — and not a round number. It was 8 performance cores for one draft, which
    /// is wrong in the most embarrassing available direction: it would have refused to even try the
    /// tier on the single machine anybody has ever run it on. "At least as much as the one machine
    /// we have data for" is the only claim the data supports.
    static let measuredPerformanceCores = 6
    static let measuredMemoryGB = 16

    public func startingIndex(among candidates: [LocalTranscriptionOption]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let last = candidates.count - 1
        guard isAppleSilicon else { return last }
        guard memoryGB >= Self.measuredMemoryGB, performanceCores >= Self.measuredPerformanceCores
        else { return last }
        return 0
    }

    // MARK: -

    static func integer(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
