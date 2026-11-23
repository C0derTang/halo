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
                              [--tracks-per-identity 5] [--seed 42] [--limit <images>]
                              [--far 0.001] [--max-wrong-label-rate 0.001]
                              [--enroll-per-person 1[,3,5]] [--gallery-images pairs|all]
                              [--min-similarity <x>] [--min-margin <y>] [--min-votes <n>]

    Detects (Apple Vision) and embeds (CoreML) every image the pair list references, then reports:
      - ROC points, FAR/FRR, and the lowest threshold with FAR <= 0.1% and <= 0.01%, on the standard
        pairs and on all cross-identity pairs of the embedded images (finer FAR resolution);
      - top-1 vs top-2 margin distributions for simulated galleries of N identities, and minMargin;
      - TrackVoter false-label rates for minVotes 2...4 on same-identity image sequences;
      - wrong-label rate and recall per gallery cell at the evaluated policy.

    --far sets minSimilarity (pair false-accept target); --max-wrong-label-rate sets minMargin (wrong
    names per probe). --min-similarity/--min-margin/--min-votes override the derived values for the
    evaluated policy. --enroll-per-person takes a list; every value x every gallery size is one cell.
    --gallery-images all also embeds every LFW image (not just pairs.txt ones) for the galleries.
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
    var wrongLabelTarget = 0.001
    var limit: Int?
    var enrollPerPerson = [1]
    var allImages = false
    var minSimilarity: Float?
    var minMargin: Float?
    var minVotes: Int?
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
        case "--max-wrong-label-rate":
            guard let v = Double(value()), v >= 0, v <= 1 else {
                fail("--max-wrong-label-rate must be in 0...1")
            }
            options.wrongLabelTarget = v
        case "--enroll-per-person":
            let list = value().split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
            guard !list.isEmpty else { fail("--enroll-per-person needs positive integers, e.g. 1,3,5") }
            options.enrollPerPerson = list
        case "--gallery-images":
            switch value() {
            case "pairs": options.allImages = false
            case "all": options.allImages = true
            default: fail("--gallery-images must be pairs or all")
            }
        case "--min-similarity":
            guard let v = Float(value()), v >= -1, v <= 1 else { fail("--min-similarity must be in -1...1") }
            options.minSimilarity = v
        case "--min-margin":
            guard let v = Float(value()), v >= 0, v <= 2 else { fail("--min-margin must be in 0...2") }
            options.minMargin = v
        case "--min-votes":
            guard let v = Int(value()), v >= 1 else { fail("--min-votes must be >= 1") }
            options.minVotes = v
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

/// Every `<name>/<name>_<nnnn>.jpg` under the LFW root, sorted.
func allImageRefs(in root: URL) -> [LFWImageRef] {
    let fm = FileManager.default
    let people = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
    return people.flatMap { person in
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(person).path)) ?? [])
            .compactMap { LFWImageRef(directory: person, fileName: $0) }
    }.sorted()
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
    // Fixed ROC points, plus the overridden minSimilarity so its FAR/FRR are reported too.
    let fixed = Array(
        Set([0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55] + [options.minSimilarity].compactMap { $0 })
    ).sorted()
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
    let derivedSimilarity = Recommender.roundUpToHundredth(thresholdPoint.threshold)
    let minSimilarity = options.minSimilarity ?? derivedSimilarity

    // 3. Open-set gallery emulation: one cell per (enrollment images per person, gallery size).
    var galleryVectors = vectors
    var galleryImages = "the \(vectors.count) `pairs.txt` images"
    if options.allImages {
        let extra = allImageRefs(in: imagesURL).filter { vectors[$0] == nil }
        log("  embedding \(extra.count) more images for galleries")
        galleryVectors.merge(await embedAll(extra, root: imagesURL, embedder: embedder)) { a, _ in a }
        galleryImages = "all \(galleryVectors.count) embedded LFW images"
    }
    let labeled = galleryVectors.keys.sorted().map {
        LabeledEmbedding(identity: $0.name, vector: galleryVectors[$0] ?? [])
    }
    let marginGrid = stride(from: 0, through: 30, by: 1).map { Float($0) / 100 }
    let fallbackMargin = marginGrid.last ?? 0.3
    struct Cell {
        var enroll: Int
        var size: Int
        var scores: [ProbeScore]
        var tracks: [SimulatedTrack]
        var suggested: OpenSetStats?
    }
    var cells: [Cell] = []
    for enroll in options.enrollPerPerson {
        for size in options.gallerySizes.sorted() {
            let split = OpenSetSimulation.split(
                labeled, gallerySize: size, enrollPerPerson: enroll, seed: options.seed)
            guard split.enrolled.count > 1 else { continue }
            let scores = OpenSetSimulation.score(split)
            cells.append(
                Cell(
                    enroll: enroll, size: split.enrolled.count, scores: scores,
                    tracks: VotingSimulation.makeTracks(
                        scores, framesPerTrack: options.frames, tracksPerIdentity: options.tracksPerIdentity,
                        seed: options.seed),
                    suggested: OpenSetSimulation.suggestMinMargin(
                        scores, minSimilarity: minSimilarity, maxFalseLabelRate: options.wrongLabelTarget,
                        candidates: marginGrid)))
            log("  gallery \(split.enrolled.count) x \(enroll) enrolled: \(scores.count) probes")
        }
    }
    guard !cells.isEmpty else { fail("no gallery could be built (too few identities with enough images)") }
    let derivedMargin = Recommender.minMargin(cells.map(\.suggested), fallback: fallbackMargin)
    let minMargin = options.minMargin ?? derivedMargin

    // 4. Per-track voting, minVotes 2...4, on the largest gallery of each enrollment count.
    var voting: [VotingResult] = []
    for enroll in options.enrollPerPerson {
        guard let cell = cells.filter({ $0.enroll == enroll }).max(by: { $0.size < $1.size }) else {
            continue
        }
        for votes in 2...4 {
            voting.append(
                VotingResult(
                    gallerySize: cell.size, enrollPerPerson: enroll,
                    stats: VotingSimulation.simulate(
                        cell.tracks,
                        policy: MatchPolicy(
                            minSimilarity: minSimilarity, minMargin: minMargin, minVotes: votes))))
        }
    }
    // The hardest case decides: per minVotes, the worst track rate over enrollment counts.
    let worstPerVotes = (2...4).compactMap { votes in
        voting.filter { $0.stats.policy.minVotes == votes }.map(\.stats)
            .max { $0.trackFalseLabelRate < $1.trackFalseLabelRate }
    }
    let currentVotes = MatchPolicy.conservative.minVotes
    let derivedVotes = Recommender.minVotes(worstPerVotes, atLeast: currentVotes) ?? currentVotes
    let evaluated = MatchPolicy(
        minSimilarity: minSimilarity, minMargin: minMargin, minVotes: options.minVotes ?? derivedVotes)

    let galleries = cells.map { cell in
        GalleryResult(
            gallerySize: cell.size, enrollPerPerson: cell.enroll,
            margins: OpenSetSimulation.marginSummaries(cell.scores, minSimilarity: minSimilarity),
            suggested: cell.suggested,
            fallback: cell.suggested == nil
                ? OpenSetSimulation.evaluate(
                    cell.scores,
                    policy: MatchPolicy(minSimilarity: minSimilarity, minMargin: fallbackMargin, minVotes: 1))
                : nil,
            atSimilarityOnly: OpenSetSimulation.evaluate(
                cell.scores, policy: MatchPolicy(minSimilarity: minSimilarity, minMargin: 0, minVotes: 1)),
            atConservative: OpenSetSimulation.evaluate(cell.scores, policy: .conservative),
            atEvaluated: OpenSetSimulation.evaluate(cell.scores, policy: evaluated),
            votingAtEvaluated: VotingSimulation.simulate(cell.tracks, policy: evaluated))
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let far = CalibrationReportFormat.pct(options.far)
    let wrong = CalibrationReportFormat.pct(options.wrongLabelTarget)
    let report = CalibrationReport(
        modelID: embedder.space.modelID,
        dataset: "LFW (`pairs.txt`, \(pairs.count) pairs)",
        date: formatter.string(from: Date()),
        imagesReferenced: refs.count, imagesEmbedded: vectors.count, pairsSkipped: skipped,
        galleryImages: galleryImages, standard: standard, extended: extended, farTarget: options.far,
        wrongLabelTarget: options.wrongLabelTarget, galleries: galleries, voting: voting,
        framesPerTrack: options.frames,
        recommended: MatchPolicy(
            minSimilarity: derivedSimilarity, minMargin: derivedMargin, minVotes: derivedVotes),
        evaluated: evaluated,
        notes: [
            "minSimilarity: lowest threshold with pair FAR ≤ \(far) on the all-pairs set, rounded up to 0.01.",
            "minMargin: smallest grid value (0.00…0.30) keeping wrong names ≤ \(wrong) of probes at the "
                + "evaluated minSimilarity in every cell, rounded up to 0.01 (a cell with none uses 0.30).",
            "minVotes: lowest worst-cell track false-label rate among 2…4, ties to more votes, never below "
                + "the current \(currentVotes). Tracks sample one identity's images with replacement, "
                + "seed \(options.seed), \(options.tracksPerIdentity) tracks per identity.",
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
