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

/// Open-set results for one simulated gallery cell (gallery size × enrollment images per person).
public struct GalleryResult: Sendable {
    /// Identities actually enrolled (can be below the requested size when too few are eligible).
    public var gallerySize: Int
    /// Enrollment images per person.
    public var enrollPerPerson: Int
    public var margins: (correct: MarginSummary, wrong: MarginSummary)
    /// Smallest margin meeting the wrong-name target at the evaluated `minSimilarity`; nil when no
    /// grid value gets there.
    public var suggested: OpenSetStats?
    /// Stats at the fallback (largest grid) margin, set only when `suggested` is nil.
    public var fallback: OpenSetStats?
    /// Stats at the evaluated `minSimilarity` with no margin gate (`minMargin` 0).
    public var atSimilarityOnly: OpenSetStats
    /// Stats at `MatchPolicy.conservative`.
    public var atConservative: OpenSetStats
    /// Per-frame stats at the evaluated policy.
    public var atEvaluated: OpenSetStats
    /// Per-track stats at the evaluated policy (its `minVotes`).
    public var votingAtEvaluated: VotingStats

    public init(
        gallerySize: Int, enrollPerPerson: Int, margins: (correct: MarginSummary, wrong: MarginSummary),
        suggested: OpenSetStats?, fallback: OpenSetStats?, atSimilarityOnly: OpenSetStats,
        atConservative: OpenSetStats, atEvaluated: OpenSetStats, votingAtEvaluated: VotingStats
    ) {
        self.gallerySize = gallerySize
        self.enrollPerPerson = enrollPerPerson
        self.margins = margins
        self.suggested = suggested
        self.fallback = fallback
        self.atSimilarityOnly = atSimilarityOnly
        self.atConservative = atConservative
        self.atEvaluated = atEvaluated
        self.votingAtEvaluated = votingAtEvaluated
    }
}

/// `TrackVoter` results for one `minVotes` on one gallery cell.
public struct VotingResult: Sendable {
    public var gallerySize: Int
    public var enrollPerPerson: Int
    public var stats: VotingStats

    public init(gallerySize: Int, enrollPerPerson: Int, stats: VotingStats) {
        self.gallerySize = gallerySize
        self.enrollPerPerson = enrollPerPerson
        self.stats = stats
    }
}

/// Turns measurements into a recommended `MatchPolicy`. Every choice errs toward *stricter*.
public enum Recommender {
    /// `value` rounded **up** to a multiple of 0.01, never below `value` as a Float.
    public static func roundUpToHundredth(_ value: Float) -> Float {
        guard value.isFinite else { return value }
        let down = Float((Double(value) * 100).rounded(.down) / 100)
        if down >= value { return down }
        return Float(((Double(value) * 100).rounded(.down) + 1) / 100)
    }

    /// The largest per-cell margin suggestion (the hardest cell decides), rounded up.
    /// A cell where no candidate reached the target (nil) contributes `fallback`.
    public static func minMargin(_ suggestions: [OpenSetStats?], fallback: Float) -> Float {
        let values = suggestions.map { $0?.policy.minMargin ?? fallback }
        return roundUpToHundredth(values.max() ?? fallback)
    }

    /// The `minVotes` with the lowest track false-label rate; on a tie, **more** votes (they never
    /// add wrong names and only cost a little latency). Never below `floor` (the current value).
    /// Nil when `voting` is empty.
    public static func minVotes(_ voting: [VotingStats], atLeast floor: Int) -> Int? {
        let best = voting.min {
            ($0.trackFalseLabelRate, -$0.policy.minVotes) < ($1.trackFalseLabelRate, -$1.policy.minVotes)
        }
        return best.map { max($0.policy.minVotes, floor) }
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
    /// Where gallery/probe images came from (e.g. "pairs.txt images", "all LFW images").
    public var galleryImages: String
    public var standard: VerificationSummary
    public var extended: VerificationSummary?
    /// Pair FAR target that sets `minSimilarity`.
    public var farTarget: Double
    /// Per-probe wrong-name target that sets `minMargin` (and is reported against for voting).
    public var wrongLabelTarget: Double
    public var galleries: [GalleryResult]
    public var voting: [VotingResult]
    public var framesPerTrack: Int
    /// Derived from the data (see `notes`).
    public var recommended: MatchPolicy
    /// The policy the per-cell grid was evaluated at (`recommended` with any command-line overrides).
    public var evaluated: MatchPolicy
    public var notes: [String]

    public init(
        modelID: String, dataset: String, date: String, imagesReferenced: Int, imagesEmbedded: Int,
        pairsSkipped: Int, galleryImages: String, standard: VerificationSummary,
        extended: VerificationSummary?,
        farTarget: Double, wrongLabelTarget: Double, galleries: [GalleryResult], voting: [VotingResult],
        framesPerTrack: Int, recommended: MatchPolicy, evaluated: MatchPolicy, notes: [String]
    ) {
        self.modelID = modelID
        self.dataset = dataset
        self.date = date
        self.imagesReferenced = imagesReferenced
        self.imagesEmbedded = imagesEmbedded
        self.pairsSkipped = pairsSkipped
        self.galleryImages = galleryImages
        self.standard = standard
        self.extended = extended
        self.farTarget = farTarget
        self.wrongLabelTarget = wrongLabelTarget
        self.galleries = galleries
        self.voting = voting
        self.framesPerTrack = framesPerTrack
        self.recommended = recommended
        self.evaluated = evaluated
        self.notes = notes
    }

    public func markdown() -> String {
        var out: [String] = []
        out.append("### Calibration: `\(modelID)` on \(dataset)")
        out.append("")
        out.append(
            "Run \(date) with `scripts/calibrate.sh`. Images: \(imagesReferenced) referenced, "
                + "\(imagesEmbedded) embedded; \(pairsSkipped) pairs skipped (no usable face). "
                + "Galleries and probes: \(galleryImages).")
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
            "**Derived:** `\(Self.policy(recommended))` (pair FAR ≤ \(Self.pct(farTarget, 3)), wrong names ≤ "
                + "\(Self.pct(wrongLabelTarget, 3)) of probes; `MatchPolicy.conservative` is unchanged in code)."
        )
        if evaluated != recommended {
            out.append("")
            out.append("**Evaluated (command-line overrides):** `\(Self.policy(evaluated))`.")
        }
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

        out.append("#### Evaluated policy per gallery cell")
        out.append("")
        out.append(
            "At `\(Self.policy(evaluated))`. Wrong-label rate = wrong names / all probes (known + unknown); "
                + "recall = right names / known probes. Tracks: \(framesPerTrack) frames, `TrackVoter`; a track "
                + "is wrong if it ever shows a wrong name and recalled if it ever shows the right one.")
        out.append("")
        out.append(
            "| Enroll/person | Gallery N | Known probes | Unknown probes | Frame wrong-label | Frame recall | "
                + "Tracks | Track wrong-label | Track recall |")
        out.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for g in galleries {
            let f = g.atEvaluated
            let t = g.votingAtEvaluated
            out.append(
                "| \(g.enrollPerPerson) | \(g.gallerySize) | \(f.knownProbes) | \(f.unknownProbes) | "
                    + "\(Self.pct(f.falseLabelRate, 4)) (\(f.wrongLabels)) | \(Self.pct(f.knownRecall, 2)) | "
                    + "\(t.tracks) | \(Self.pct(t.trackFalseLabelRate, 3)) (\(t.tracksEverWrong)) | "
                    + "\(Self.pct(t.knownTrackRecall, 2)) |")
        }
        out.append("")

        out.append("#### Open-set gallery emulation (top-1 vs top-2 margin, per frame)")
        out.append("")
        out.append(
            "Margins of probes whose top-1 clears `minSimilarity` = \(Self.num(evaluated.minSimilarity)). "
                + "Cells read false-label / recall; \"Suggested\" is at the suggested margin, or at the fallback "
                + "(largest grid) margin when none meets the target.")
        out.append("")
        out.append(
            "| Enroll/person | Gallery N | Correct margin p1 / p5 / p50 | Wrong margin p50 / p99 / max | "
                + "Suggested minMargin | Suggested | Similarity only | Conservative |")
        out.append("|---:|---:|---|---|---:|---|---|---|")
        for g in galleries {
            let c = g.margins.correct
            let w = g.margins.wrong
            let margin: String
            let at: OpenSetStats
            if let suggested = g.suggested {
                margin = Self.num(suggested.policy.minMargin)
                at = suggested
            } else {
                at = g.fallback ?? g.atSimilarityOnly
                margin = "none; fallback \(Self.num(at.policy.minMargin))"
            }
            out.append(
                "| \(g.enrollPerPerson) | \(g.gallerySize) | "
                    + "\(Self.opt(c.p1)) / \(Self.opt(c.p5)) / \(Self.opt(c.p50)) | "
                    + "\(Self.opt(w.p50)) / \(Self.opt(w.p99)) / \(Self.opt(w.max)) (n=\(w.count)) | \(margin) | "
                    + "\(Self.rates(at)) | \(Self.rates(g.atSimilarityOnly)) | \(Self.rates(g.atConservative)) |"
            )
        }
        out.append("")

        out.append(
            "#### Per-track voting (`TrackVoter`, \(framesPerTrack) frames per track, evaluated thresholds)")
        out.append("")
        out.append(
            "| Enroll/person | Gallery N | minVotes | Tracks | Tracks ever wrong | Frames wrong | Known-track recall |"
        )
        out.append("|---:|---:|---:|---:|---:|---:|---:|")
        for r in voting {
            let v = r.stats
            out.append(
                "| \(r.enrollPerPerson) | \(r.gallerySize) | \(v.policy.minVotes) | \(v.tracks) | "
                    + "\(v.tracksEverWrong) (\(Self.pct(v.trackFalseLabelRate, 3))) | "
                    + "\(Self.pct(v.frameFalseLabelRate, 4)) | \(Self.pct(v.knownTrackRecall, 2)) |")
        }
        if !notes.isEmpty {
            out.append("")
            out.append(contentsOf: notes.map { "- \($0)" })
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    static func policy(_ p: MatchPolicy) -> String {
        "MatchPolicy(minSimilarity: \(num(p.minSimilarity)), minMargin: \(num(p.minMargin)), "
            + "minVotes: \(p.minVotes))"
    }

    static func rates(_ s: OpenSetStats) -> String {
        "\(pct(s.falseLabelRate, 4)) / \(pct(s.knownRecall, 2))"
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
