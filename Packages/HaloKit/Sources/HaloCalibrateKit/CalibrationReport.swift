import Foundation
import HaloCore

/// Summary of one verification pair set at the FAR targets and a few fixed thresholds.
public struct VerificationSummary: Sendable {
    public var name: String
    public var genuineCount: Int
    public var impostorCount: Int
    public var farResolution: Double
    public var targets: [(far: Double, point: OperatingPoint?)]
    /// ROC points at fixed thresholds.
    public var fixed: [OperatingPoint]
    /// k-fold accuracies (standard protocol only).
    public var kFold: [Double]
    public var equalErrorRate: Double?

    public init(
        name: String, curve: VerificationCurve, farTargets: [Double], fixedThresholds: [Float],
        kFold: [Double] = [], includeEER: Bool = true
    ) {
        self.name = name
        genuineCount = curve.genuine.count
        impostorCount = curve.impostor.count
        farResolution = curve.farResolution
        targets = farTargets.map { ($0, curve.threshold(forFAR: $0)) }
        fixed = fixedThresholds.map { curve.point(at: $0) }
        self.kFold = kFold
        equalErrorRate = includeEER ? curve.equalErrorRate()?.rate : nil
    }

    public func point(forFAR far: Double) -> OperatingPoint? {
        targets.first { $0.far == far }?.point
    }
}

/// Open-set results for one simulated gallery size.
public struct GalleryResult: Sendable {
    public var gallerySize: Int
    public var margins: (correct: MarginSummary, wrong: MarginSummary)
    /// Smallest margin meeting the false-label target at the recommended `minSimilarity`.
    public var suggested: OpenSetStats?
    public var atRecommended: OpenSetStats
    public var atConservative: OpenSetStats

    public init(
        gallerySize: Int, margins: (correct: MarginSummary, wrong: MarginSummary), suggested: OpenSetStats?,
        atRecommended: OpenSetStats, atConservative: OpenSetStats
    ) {
        self.gallerySize = gallerySize
        self.margins = margins
        self.suggested = suggested
        self.atRecommended = atRecommended
        self.atConservative = atConservative
    }
}

/// Turns measurements into a recommended `MatchPolicy`. Every rounding is toward *stricter*.
public enum Recommender {
    /// `value` rounded **up** to a multiple of 0.01, never below `value` as a Float.
    public static func roundUpToHundredth(_ value: Float) -> Float {
        guard value.isFinite else { return value }
        let down = Float((Double(value) * 100).rounded(.down) / 100)
        if down >= value { return down }
        return Float(((Double(value) * 100).rounded(.down) + 1) / 100)
    }

    /// The largest per-gallery margin suggestion (the hardest gallery decides), rounded up.
    /// A gallery where no candidate reached the target contributes `fallback`.
    public static func minMargin(_ galleries: [GalleryResult], fallback: Float) -> Float {
        let values = galleries.map { $0.suggested?.policy.minMargin ?? fallback }
        return roundUpToHundredth(values.max() ?? fallback)
    }

    /// The smallest `minVotes` whose track false-label rate is `<= maxTrackFalseLabelRate`; when none
    /// is, the one with the lowest rate (ties: more votes).
    public static func minVotes(_ voting: [VotingStats], maxTrackFalseLabelRate: Double) -> Int? {
        let sorted = voting.sorted { $0.policy.minVotes < $1.policy.minVotes }
        if let ok = sorted.first(where: { $0.trackFalseLabelRate <= maxTrackFalseLabelRate }) {
            return ok.policy.minVotes
        }
        return sorted.min {
            ($0.trackFalseLabelRate, -$0.policy.minVotes) < ($1.trackFalseLabelRate, -$1.policy.minVotes)
        }?.policy.minVotes
    }
}

/// Everything one calibration run measured, rendered as the `docs/MODELS.md` section.
/// Aggregates only: no image names, identities or per-image scores.
public struct CalibrationReport: Sendable {
    public var modelID: String
    public var dataset: String
    public var date: String
    public var imagesReferenced: Int
    public var imagesEmbedded: Int
    public var pairsSkipped: Int
    public var standard: VerificationSummary
    public var extended: VerificationSummary?
    public var farTarget: Double
    public var galleries: [GalleryResult]
    public var voting: [VotingStats]
    public var framesPerTrack: Int
    public var recommended: MatchPolicy
    public var notes: [String]

    public init(
        modelID: String, dataset: String, date: String, imagesReferenced: Int, imagesEmbedded: Int,
        pairsSkipped: Int, standard: VerificationSummary, extended: VerificationSummary?, farTarget: Double,
        galleries: [GalleryResult], voting: [VotingStats], framesPerTrack: Int, recommended: MatchPolicy,
        notes: [String]
    ) {
        self.modelID = modelID
        self.dataset = dataset
        self.date = date
        self.imagesReferenced = imagesReferenced
        self.imagesEmbedded = imagesEmbedded
        self.pairsSkipped = pairsSkipped
        self.standard = standard
        self.extended = extended
        self.farTarget = farTarget
        self.galleries = galleries
        self.voting = voting
        self.framesPerTrack = framesPerTrack
        self.recommended = recommended
        self.notes = notes
    }

    public func markdown() -> String {
        var out: [String] = []
        out.append("### Calibration: `\(modelID)` on \(dataset)")
        out.append("")
        out.append(
            "Run \(date) with `scripts/calibrate.sh`. Images: \(imagesReferenced) referenced, "
                + "\(imagesEmbedded) embedded; \(pairsSkipped) pairs skipped (no usable face).")
        if !standard.kFold.isEmpty {
            let mean = standard.kFold.reduce(0, +) / Double(standard.kFold.count)
            let variance =
                standard.kFold.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(standard.kFold.count)
            out.append(
                "Standard \(standard.kFold.count)-fold accuracy: \(Self.pct(mean, 2)) ± "
                    + "\(Self.pct(variance.squareRoot(), 2))"
                    + (standard.equalErrorRate.map { "; EER \(Self.pct($0, 2))" } ?? "") + ".")
        }
        out.append("")
        out.append(
            "**Recommended:** `MatchPolicy(minSimilarity: \(Self.num(recommended.minSimilarity)), "
                + "minMargin: \(Self.num(recommended.minMargin)), minVotes: \(recommended.minVotes))` "
                + "(target FAR ≤ \(Self.pct(farTarget, 3)); `MatchPolicy.conservative` is unchanged in code)."
        )
        out.append("")

        out.append("#### Verification (accept iff cosine ≥ threshold)")
        out.append("")
        out.append("| Pair set | Genuine | Impostor | FAR target | Threshold | FAR | FRR |")
        out.append("|----------|--------:|---------:|-----------:|----------:|----:|----:|")
        for summary in [standard] + (extended.map { [$0] } ?? []) {
            for (far, point) in summary.targets {
                let resolvable = far >= summary.farResolution
                let threshold = point.map { Self.num($0.threshold, 4) } ?? "n/a"
                out.append(
                    "| \(summary.name) | \(summary.genuineCount) | \(summary.impostorCount) | "
                        + "\(Self.pct(far, 3))\(resolvable ? "" : " (below resolution)") | \(threshold) | "
                        + "\(point.map { Self.pct($0.far, 4) } ?? "n/a") | \(point.map { Self.pct($0.frr, 2) } ?? "n/a") |"
                )
            }
        }
        out.append("")

        out.append("#### ROC points at fixed thresholds")
        out.append("")
        out.append("| Pair set | Threshold | FAR | FRR |")
        out.append("|----------|----------:|----:|----:|")
        for summary in [standard] + (extended.map { [$0] } ?? []) {
            for p in summary.fixed {
                out.append(
                    "| \(summary.name) | \(Self.num(p.threshold)) | \(Self.pct(p.far, 4)) | \(Self.pct(p.frr, 2)) |"
                )
            }
        }
        out.append("")

        out.append("#### Open-set gallery emulation (top-1 vs top-2 margin, per frame)")
        out.append("")
        out.append(
            "Margins of probes whose top-1 clears `minSimilarity` = \(Self.num(recommended.minSimilarity)). "
                + "False-label rate = wrong names / all probes (known + unknown).")
        out.append("")
        out.append(
            "| Gallery N | Known probes | Unknown probes | Correct margin p1 / p5 / p50 | Wrong margin p50 / p99 / max | "
                + "Suggested minMargin | False-label rate | Known recall | Conservative: false-label / recall |"
        )
        out.append("|---:|---:|---:|---|---|---:|---:|---:|---|")
        for g in galleries {
            let c = g.margins.correct
            let w = g.margins.wrong
            let suggested = g.suggested.map { Self.num($0.policy.minMargin) } ?? "none in grid"
            let at = g.suggested ?? g.atRecommended
            out.append(
                "| \(g.gallerySize) | \(g.atRecommended.knownProbes) | \(g.atRecommended.unknownProbes) | "
                    + "\(Self.opt(c.p1)) / \(Self.opt(c.p5)) / \(Self.opt(c.p50)) | "
                    + "\(Self.opt(w.p50)) / \(Self.opt(w.p99)) / \(Self.opt(w.max)) (n=\(w.count)) | \(suggested) | "
                    + "\(Self.pct(at.falseLabelRate, 4)) | \(Self.pct(at.knownRecall, 2)) | "
                    + "\(Self.pct(g.atConservative.falseLabelRate, 4)) / \(Self.pct(g.atConservative.knownRecall, 2)) |"
            )
        }
        out.append("")

        out.append(
            "#### Per-track voting (`TrackVoter`, \(framesPerTrack) frames per track, recommended thresholds)"
        )
        out.append("")
        out.append("| minVotes | Tracks | Tracks ever wrong | Frames wrong | Known-track recall |")
        out.append("|---:|---:|---:|---:|---:|")
        for v in voting {
            out.append(
                "| \(v.policy.minVotes) | \(v.tracks) | \(v.tracksEverWrong) (\(Self.pct(v.trackFalseLabelRate, 3))) | "
                    + "\(Self.pct(v.frameFalseLabelRate, 4)) | \(Self.pct(v.knownTrackRecall, 2)) |")
        }
        if !notes.isEmpty {
            out.append("")
            out.append(contentsOf: notes.map { "- \($0)" })
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    static func pct(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }

    static func num(_ value: Float, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", Double(value))
    }

    static func opt(_ value: Float?) -> String {
        value.map { num($0, 3) } ?? "n/a"
    }
}
