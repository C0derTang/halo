// halo-calibrate: measures the face model's verification error rates on a PUBLIC benchmark (LFW)
// and recommends `MatchPolicy` thresholds (invariant 4). macOS only. Never point it at personal
// photos. Output is aggregate statistics only: no identities, file names or per-image scores.
//
// Usage: see `usage` below, or run ./scripts/calibrate.sh.

import CoreGraphics
import Foundation
import HaloCalibrateKit
import HaloCore
import HaloVision
import ImageIO

let usage = """
    usage: halo-calibrate run --model <HaloFaceEmbedder.mlmodelc> --pairs <pairs.txt> --images <lfw dir>
                              [--report <out.md>] [--gallery-sizes 10,50,200] [--frames 10]
                              [--tracks-per-identity 5] [--seed 42] [--far 0.001] [--limit <images>]

    Detects (Apple Vision) and embeds (CoreML) every image the pair list references, then reports:
      - ROC points, FAR/FRR, and the lowest threshold with FAR <= 0.1% and <= 0.01%, on the standard
        pairs and on all cross-identity pairs of the embedded images (finer FAR resolution);
      - top-1 vs top-2 margin distributions for simulated galleries of N identities, and minMargin;
      - TrackVoter false-label rates for minVotes 2...4 on same-identity image sequences.
    Skips (exit 0) when the model or dataset is absent.
    """

struct Options {
    var model: URL?
    var pairs: URL?
    var images: URL?
    var report: URL?
    var gallerySizes = [10, 50, 200]
    var frames = 10
    var tracksPerIdentity = 5
    var seed: UInt64 = 42
    var far = 0.001
    var limit: Int?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("halo-calibrate: \(message)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])\n\(usage)") }
        return args[i]
    }
    func url(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    while i < args.count {
        switch args[i] {
        case "--model": options.model = url(value())
        case "--pairs": options.pairs = url(value())
        case "--images": options.images = url(value())
        case "--report": options.report = url(value())
        case "--gallery-sizes":
            options.gallerySizes = value().split(separator: ",").compactMap { Int($0) }.filter { $0 > 1 }
        case "--frames": options.frames = Int(value()) ?? options.frames
        case "--tracks-per-identity": options.tracksPerIdentity = Int(value()) ?? options.tracksPerIdentity
        case "--seed": options.seed = UInt64(value()) ?? options.seed
        case "--far": options.far = Double(value()) ?? options.far
        case "--limit": options.limit = Int(value())
        case "-h", "--help":
            print(usage)
            exit(0)
        default: fail("unknown argument \(args[i])\n\(usage)")
        }
        i += 1
    }
    return options
}

func skip(_ reason: String) -> Never {
    print("halo-calibrate: skipped: \(reason)")
    exit(0)
}

/// Picks LFW's subject: the face (with five landmarks for alignment) closest to the image centre.
func subjectFace(_ faces: [HaloCore.FaceObservation]) -> HaloCore.FaceObservation? {
    faces.filter { $0.landmarks.count == FivePointLandmarks.count }.min {
        hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5)
            < hypot($1.boundingBox.midX - 0.5, $1.boundingBox.midY - 0.5)
    }
}

func embedAll(_ refs: [LFWImageRef], root: URL, embedder: CoreMLFaceEmbedder) async -> [LFWImageRef: [Float]]
{
    let detector = VisionFaceDetector()
    var result: [LFWImageRef: [Float]] = [:]
    var done = 0
    await withTaskGroup(of: (LFWImageRef, [Float]?).self) { group in
        var next = 0
        func add() {
            guard next < refs.count else { return }
            let ref = refs[next]
            next += 1
            group.addTask {
                let url = root.appendingPathComponent(ref.relativePath)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                    let faces = try? await detector.detectFaces(in: image, timestamp: 0),
                    let face = subjectFace(faces),
                    let vector = try? await embedder.embed(face: face, in: image)
                else { return (ref, nil) }
                return (ref, vector)
            }
        }
        for _ in 0..<8 { add() }
        for await (ref, vector) in group {
            if let vector { result[ref] = vector }
            done += 1
            if done % 500 == 0 { log("  embedded \(done)/\(refs.count)") }
            add()
        }
    }
    return result
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

func run(_ options: Options) async {
    guard let modelURL = options.model, let pairsURL = options.pairs, let imagesURL = options.images else {
        fail("--model, --pairs and --images are required\n\(usage)")
    }
    let fm = FileManager.default
    guard fm.fileExists(atPath: modelURL.path) else {
        skip("no model at \(modelURL.path) (run scripts/fetch-models.sh)")
    }
    guard fm.fileExists(atPath: pairsURL.path), fm.fileExists(atPath: imagesURL.path) else {
        skip("no dataset at \(pairsURL.path) / \(imagesURL.path) (run scripts/calibrate.sh)")
    }

    let pairs: [LFWPair]
    do {
        pairs = try LFWPairs.parse(try String(contentsOf: pairsURL, encoding: .utf8))
    } catch {
        fail("cannot read pair list: \(error)")
    }
    var refs = LFWPairs.images(in: pairs)
    if let limit = options.limit { refs = Array(refs.prefix(limit)) }

    let embedder: CoreMLFaceEmbedder
    do {
        embedder = try await CoreMLFaceEmbedder.load(compiledModelAt: modelURL)
    } catch {
        fail("cannot load model: \(error)")
    }
    log("halo-calibrate: \(pairs.count) pairs, \(refs.count) images, model \(embedder.space.modelID)")
    let vectors = await embedAll(refs, root: imagesURL, embedder: embedder)
    log("  \(vectors.count)/\(refs.count) images embedded")

    // 1. Standard protocol: the listed pairs.
    var scored: [ScoredPair] = []
    var skipped = 0
    for pair in pairs {
        guard let a = vectors[pair.first], let b = vectors[pair.second] else {
            skipped += 1
            continue
        }
        scored.append(ScoredPair(score: dot(a, b), isGenuine: pair.isGenuine, fold: pair.fold))
    }
    let farTargets = [0.01, 0.001, 0.0001]
    let fixed: [Float] = [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55]
    let standard = VerificationSummary(
        name: "pairs.txt", curve: VerificationCurve(pairs: scored), farTargets: farTargets,
        fixedThresholds: fixed, kFold: VerificationCurve.kFoldAccuracy(scored))

    // 2. Extended: every pair among the embedded images (finer FAR resolution for the tail).
    let embedded = vectors.keys.sorted()
    let all = VerificationCurve.allPairScores(
        vectors: embedded.map { vectors[$0] ?? [] }, labels: embedded.map(\.name))
    let extendedCurve = VerificationCurve(genuineScores: all.genuine, impostorScores: all.impostor)
    let extended = VerificationSummary(
        name: "all pairs", curve: extendedCurve, farTargets: farTargets, fixedThresholds: fixed,
        includeEER: false)
    log("  extended: \(extendedCurve.genuine.count) genuine, \(extendedCurve.impostor.count) impostor pairs")

    guard
        let thresholdPoint = extendedCurve.threshold(forFAR: options.far)
            ?? standard.point(forFAR: options.far)
    else { fail("no impostor pairs; cannot pick a threshold") }
    let minSimilarity = Recommender.roundUpToHundredth(thresholdPoint.threshold)

    // 3. Open-set gallery emulation.
    let labeled = embedded.map { LabeledEmbedding(identity: $0.name, vector: vectors[$0] ?? []) }
    let marginGrid = stride(from: 0, through: 30, by: 1).map { Float($0) / 100 }
    var galleries: [GalleryResult] = []
    var hardestScores: [ProbeScore] = []
    for size in options.gallerySizes.sorted() {
        let split = OpenSetSimulation.split(labeled, gallerySize: size, seed: options.seed)
        guard split.enrolled.count > 1 else { continue }
        let scores = OpenSetSimulation.score(split)
        let suggested = OpenSetSimulation.suggestMinMargin(
            scores, minSimilarity: minSimilarity, maxFalseLabelRate: options.far, candidates: marginGrid)
        let atSimilarityOnly = OpenSetSimulation.evaluate(
            scores, policy: MatchPolicy(minSimilarity: minSimilarity, minMargin: 0, minVotes: 1))
        galleries.append(
            GalleryResult(
                gallerySize: split.enrolled.count,
                margins: OpenSetSimulation.marginSummaries(scores, minSimilarity: minSimilarity),
                suggested: suggested, atRecommended: atSimilarityOnly,
                atConservative: OpenSetSimulation.evaluate(scores, policy: .conservative)))
        hardestScores = scores
        log("  gallery \(split.enrolled.count): \(scores.count) probes")
    }
    let minMargin = Recommender.minMargin(galleries, fallback: marginGrid.last ?? 0.3)

    // 4. Per-track voting on the largest gallery.
    let tracks = VotingSimulation.makeTracks(
        hardestScores, framesPerTrack: options.frames, tracksPerIdentity: options.tracksPerIdentity,
        seed: options.seed)
    let voting = (2...4).map {
        VotingSimulation.simulate(
            tracks, policy: MatchPolicy(minSimilarity: minSimilarity, minMargin: minMargin, minVotes: $0))
    }
    let minVotes = Recommender.minVotes(voting, maxTrackFalseLabelRate: options.far) ?? 3

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let report = CalibrationReport(
        modelID: embedder.space.modelID,
        dataset: "LFW (`pairs.txt`, \(pairs.count) pairs)",
        date: formatter.string(from: Date()),
        imagesReferenced: refs.count, imagesEmbedded: vectors.count, pairsSkipped: skipped,
        standard: standard, extended: extended, farTarget: options.far, galleries: galleries,
        voting: voting, framesPerTrack: options.frames,
        recommended: MatchPolicy(minSimilarity: minSimilarity, minMargin: minMargin, minVotes: minVotes),
        notes: [
            "minSimilarity: lowest threshold with FAR ≤ \(CalibrationReportFormat.pct(options.far)) on "
                + "the all-pairs set, rounded up to 0.01.",
            "minMargin: smallest grid value (0.00…0.30) keeping the per-frame false-label rate ≤ "
                + "\(CalibrationReportFormat.pct(options.far)) in every gallery size, rounded up to 0.01.",
            "minVotes: smallest of 2…4 with track false-label rate ≤ \(CalibrationReportFormat.pct(options.far)) "
                + "(else the lowest-rate one); tracks sample one identity's images with replacement, "
                + "seed \(options.seed).",
        ])
    let markdown = report.markdown()
    print(markdown)
    if let reportURL = options.report {
        do {
            try markdown.write(to: reportURL, atomically: true, encoding: .utf8)
            log("halo-calibrate: wrote \(reportURL.path)")
        } catch {
            fail("cannot write report: \(error)")
        }
    }
}

enum CalibrationReportFormat {
    static func pct(_ value: Double) -> String { String(format: "%g%%", value * 100) }
}

#if os(macOS)
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "run" else {
        print(usage)
        exit(arguments.isEmpty || arguments.first == "--help" || arguments.first == "-h" ? 0 : 2)
    }
    await run(parseOptions(Array(arguments.dropFirst())))
#else
    print("halo-calibrate runs on macOS only")
#endif
