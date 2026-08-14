import Foundation

/// Downloading and measuring one candidate, behind a seam.
///
/// A protocol for one reason: the ladder in ``FitRunner`` — where to start, when to step down, what
/// the cap does, what happens when a measurement throws — is the part that has to be right, and none
/// of it should need 600 MB of Core ML and a Neural Engine to test.
public protocol FitProbe: Sendable {
    func download(
        _ option: LocalTranscriptionOption,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws

    func measure(_ option: LocalTranscriptionOption, fixture: SpeechFixture) async throws -> FitMeasurement
}

/// Where the run has got to, for a progress line the user can read.
public enum FitStage: Sendable, Equatable {
    case profiling
    case downloading(option: String, fraction: Double)
    case measuring(option: String)
    case steppingDown(from: String, to: String, because: String)
    case done(chosen: String)
}

/// Picks the transcription model that verifiably runs well on *this* Mac.
///
/// The shape is forced by the cost of being wrong in the other direction: you cannot benchmark a
/// model you have not downloaded, and downloading every candidate to race them would be several
/// gigabytes during onboarding. So it is profile → start somewhere plausible → download one →
/// **measure it here** → accept or step down. The profile only chooses where to start; the
/// measurement decides.
///
/// Three rules it does not bend:
///
///   * A candidate is accepted only on numbers this run produced.
///   * When nothing can be measured — no speech synthesis, no disk, a failed download — the result
///     is ``LocalTranscriptionOption/fallback`` with `verified: false` and a reason saying exactly
///     that. Never a silent unverified pick.
///   * There is a wall-clock cap, it is recorded in the result, and a run that hits it stops with
///     whatever it has rather than running on.
public struct FitRunner: Sendable {
    /// Total wall clock, downloads included. Onboarding is the caller, and a setup step that can run
    /// for an unbounded number of minutes is worse than no fit at all — the user cannot tell it from
    /// a hang. Six minutes is roughly one 640 MB download on a slow connection plus one measurement;
    /// past that the fallback is the better answer.
    public static let defaultCap: TimeInterval = 360

    let probe: any FitProbe
    let profile: MachineProfile
    let candidates: [LocalTranscriptionOption]
    let thresholds: FitThresholds
    let cap: TimeInterval
    let now: @Sendable () -> Date

    public init(
        probe: any FitProbe,
        profile: MachineProfile = .current(),
        candidates: [LocalTranscriptionOption] = LocalTranscriptionOption.all,
        thresholds: FitThresholds = .standard,
        cap: TimeInterval = FitRunner.defaultCap,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probe = probe
        self.profile = profile
        self.candidates = candidates
        self.thresholds = thresholds
        self.cap = cap
        self.now = now
    }

    /// Runs the ladder. Never throws: every failure is a reason in the returned record, because a
    /// `fit` that throws leaves the caller with no model chosen at all.
    public func run(
        fixture: SpeechFixture?,
        stage: @Sendable @escaping (FitStage) -> Void = { _ in }
    ) async -> FitRecord {
        let started = now()
        stage(.profiling)

        guard let fixture else {
            return fallbackRecord(
                started: started, measurements: [],
                reason: "no speech fixture could be synthesised on this Mac, so nothing was "
                    + "measured. Staying on the model that has always shipped")
        }
        guard !candidates.isEmpty else {
            return fallbackRecord(
                started: started, measurements: [], reason: "there are no candidates to try")
        }

        var measurements: [FitMeasurement] = []
        var index = profile.startingIndex(among: candidates)
        var lastFailure: String?

        while index < candidates.count {
            let candidate = candidates[index]
            guard remaining(since: started) > 0 else {
                return cappedRecord(started: started, measurements: measurements)
            }

            do {
                stage(.downloading(option: candidate.id, fraction: 0))
                try await probe.download(candidate) { stage(.downloading(option: candidate.id, fraction: $0)) }
                stage(.measuring(option: candidate.id))
                let measurement = try await probe.measure(candidate, fixture: fixture)
                measurements.append(measurement)

                if measurement.meets(thresholds) {
                    stage(.done(chosen: candidate.id))
                    return FitRecord(
                        chosenOptionID: candidate.id,
                        reason: "\(measurement.sentence) on your \(profile.chip)",
                        verified: true, machine: profile, thresholds: thresholds,
                        measurements: measurements, ranAt: started, capSeconds: cap)
                }
                lastFailure = "\(candidate.title) managed only \(measurement.sentence), under the "
                    + String(format: "%.1fx", thresholds.realTimeFactor)
                    + " and \(thresholds.timeToFirstTextMs) ms this needs"
            } catch {
                lastFailure = "\(candidate.title) could not be measured: \(error)"
            }

            let next = index + 1
            if next < candidates.count {
                stage(.steppingDown(
                    from: candidate.id, to: candidates[next].id, because: lastFailure ?? ""))
            }
            index = next
        }

        // Every candidate was tried and none cleared the bar. The last one is the fallback by
        // construction, and it is still what runs — there is nothing below it — but the record says
        // it was chosen despite its numbers rather than because of them.
        let last = candidates[candidates.count - 1]
        let itsNumbers = measurements.last(where: { $0.optionID == last.id })
        return FitRecord(
            chosenOptionID: last.id,
            reason: itsNumbers.map {
                "nothing cleared the bar on this Mac. \(last.title) is the fallback and measured "
                    + "\($0.sentence)"
            } ?? (lastFailure ?? "nothing could be measured"),
            verified: itsNumbers != nil, machine: profile, thresholds: thresholds,
            measurements: measurements, ranAt: started, capSeconds: cap)
    }

    // MARK: -

    private func remaining(since started: Date) -> TimeInterval {
        cap - now().timeIntervalSince(started)
    }

    private func fallbackRecord(
        started: Date, measurements: [FitMeasurement], reason: String
    ) -> FitRecord {
        FitRecord(
            chosenOptionID: LocalTranscriptionOption.fallback.id, reason: reason, verified: false,
            machine: profile, thresholds: thresholds, measurements: measurements,
            ranAt: started, capSeconds: cap)
    }

    private func cappedRecord(started: Date, measurements: [FitMeasurement]) -> FitRecord {
        // Anything already measured and passing would have returned above, so what is left is a
        // fallback — but a fallback that was measured is still a verified one, and saying otherwise
        // would throw away a real number.
        let fallback = LocalTranscriptionOption.fallback
        if let measured = measurements.last(where: { $0.optionID == fallback.id }) {
            return FitRecord(
                chosenOptionID: fallback.id,
                reason: "the \(Int(cap)) second limit was reached. \(fallback.title) measured "
                    + measured.sentence,
                verified: true, machine: profile, thresholds: thresholds,
                measurements: measurements, ranAt: started, capSeconds: cap)
        }
        return fallbackRecord(
            started: started, measurements: measurements,
            reason: "the \(Int(cap)) second limit was reached before anything could be measured, so "
                + "the model that has always shipped is what stays selected")
    }
}
