import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import HaloCore
import ImageIO

/// `FaceEmbedder` / `FrameFaceEmbedding` backed by a compiled CoreML face-recognition model (see
/// `docs/MODELS.md` and `scripts/fetch-models.sh`).
///
/// **App entry point:** `try await CoreMLFaceEmbedder.load(directory: Bundle.main.resourceURL!)`.
/// `load` runs the slow, blocking CoreML model load on the concurrent executor, so app startup
/// never loads the model on the main actor. The synchronous initializers remain for tests and for
/// callers that are already off the main actor.
///
/// Pipeline per face: `FaceAligner` 112x112 crop -> model input -> raw vector -> L2 normalization.
/// Live frames are aligned straight from the camera pixel buffer honouring `VideoFrame.orientation`
/// (Core Image renders only the 112x112 crop; no full-frame `CGImage` copy).
/// Accepts models whose input is either a 112x112 image or a float32 `[1, 3, 112, 112]` /
/// `[3, 112, 112]` tensor (normalized per `Preprocessing`), and whose output is a float vector.
///
/// An actor: predictions are serialized off the main actor, and the non-Sendable `MLModel` never
/// escapes it. Nothing here touches the network or logs pixels/vectors (invariant 2).
public actor CoreMLFaceEmbedder: FaceEmbedder, FrameFaceEmbedding {
    /// File name `fetch-models.sh` produces and the app bundles.
    public static let defaultModelName = "HaloFaceEmbedder"
    /// `EmbeddingSpace.modelID` for the default weights. Change whenever the weights OR the
    /// alignment/preprocessing change (`FaceAligner`, `Preprocessing`): embeddings from different
    /// pipelines are not comparable, and a stale ID would let them be matched against each other.
    public static let defaultModelID = "insightface-w600k_mbf-buffalo_sc-v0.7"

    /// Tensor-input normalization: `(pixel - mean) * scale`, channels in `channelOrder`.
    public struct Preprocessing: Hashable, Sendable {
        public enum ChannelOrder: Hashable, Sendable { case rgb, bgr }
        public var mean: Float
        public var scale: Float
        public var channelOrder: ChannelOrder

        public init(mean: Float, scale: Float, channelOrder: ChannelOrder) {
            self.mean = mean
            self.scale = scale
            self.channelOrder = channelOrder
        }

        /// InsightFace w600k / ArcFace ONNX models: RGB, `(x - 127.5) / 127.5`.
        public static let arcFace = Preprocessing(mean: 127.5, scale: 1 / 127.5, channelOrder: .rgb)
    }

    enum InputKind: Equatable {
        case image
        case tensor(shape: [Int])
    }

    public nonisolated let space: EmbeddingSpace
    private let model: MLModel
    private let inputName: String
    private let inputKind: InputKind
    private let outputName: String
    private let preprocessing: Preprocessing
    private let aligner: FaceAligner

    /// Loads a compiled (`.mlmodelc`) model.
    ///
    /// - Throws: `HaloVisionError.modelNotFound` when nothing is at `url`,
    ///   `.modelNotCompiled` for `.mlmodel` / `.mlpackage`, `.modelLoadFailed` when CoreML rejects
    ///   it, `.unsupportedModel` when its I/O is not a 112x112 face -> vector model.
    public init(
        compiledModelAt url: URL, modelID: String = CoreMLFaceEmbedder.defaultModelID,
        preprocessing: Preprocessing = .arcFace, aligner: FaceAligner = FaceAligner(),
        computeUnits: MLComputeUnits = .all
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HaloVisionError.modelNotFound(url)
        }
        guard url.pathExtension == "mlmodelc" else { throw HaloVisionError.modelNotCompiled(url) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw HaloVisionError.modelLoadFailed(error.localizedDescription)
        }
        let io = try Self.inspect(model.modelDescription)
        self.model = model
        self.inputName = io.inputName
        self.inputKind = io.inputKind
        self.outputName = io.outputName
        self.space = EmbeddingSpace(modelID: modelID, dimension: io.dimension)
        self.preprocessing = preprocessing
        self.aligner = aligner
    }

    /// Convenience: `<directory>/HaloFaceEmbedder.mlmodelc` (e.g. the app bundle's resources).
    public init(
        directory: URL, modelID: String = CoreMLFaceEmbedder.defaultModelID,
        computeUnits: MLComputeUnits = .all
    ) throws {
        try self.init(
            compiledModelAt: directory.appendingPathComponent("\(Self.defaultModelName).mlmodelc"),
            modelID: modelID, computeUnits: computeUnits)
    }

    /// Loads `<directory>/HaloFaceEmbedder.mlmodelc` off the main actor. The app's entry point.
    ///
    /// - Throws: the same typed `HaloVisionError`s as `init(compiledModelAt:)`.
    @concurrent
    public static func load(
        directory: URL, modelID: String = CoreMLFaceEmbedder.defaultModelID,
        computeUnits: MLComputeUnits = .all
    ) async throws -> CoreMLFaceEmbedder {
        try await offMainActor {
            try CoreMLFaceEmbedder(directory: directory, modelID: modelID, computeUnits: computeUnits)
        }
    }

    /// Loads a compiled (`.mlmodelc`) model off the main actor.
    ///
    /// - Throws: the same typed `HaloVisionError`s as `init(compiledModelAt:)`.
    @concurrent
    public static func load(
        compiledModelAt url: URL, modelID: String = CoreMLFaceEmbedder.defaultModelID,
        preprocessing: Preprocessing = .arcFace, aligner: FaceAligner = FaceAligner(),
        computeUnits: MLComputeUnits = .all
    ) async throws -> CoreMLFaceEmbedder {
        try await offMainActor {
            try CoreMLFaceEmbedder(
                compiledModelAt: url, modelID: modelID, preprocessing: preprocessing, aligner: aligner,
                computeUnits: computeUnits)
        }
    }

    /// Runs `body` on the concurrent executor, whatever actor the caller is on.
    @concurrent
    static func offMainActor<T: Sendable>(_ body: @Sendable () throws -> T) async throws -> T {
        try body()
    }

    public func embed(face: FaceObservation, in image: CGImage) async throws -> [Float] {
        try embedSynchronously(try aligner.alignedFace(face, in: image))
    }

    /// Embeds a face from a stored image whose display orientation is `orientation` (e.g. a PhotoKit
    /// asset's EXIF orientation). `face` is in the upright image, as `VisionFaceDetector` returns it.
    public func embed(face: FaceObservation, in image: CGImage, orientation: CGImagePropertyOrientation)
        async throws -> [Float]
    {
        let source = CIImage(cgImage: image)
        return try embedSynchronously(try aligner.alignedFace(face, in: source, orientation: orientation))
    }

    /// Embeds a face from a live camera frame. `face` is in the frame's upright space.
    public func embed(face: FaceObservation, in frame: VideoFrame) async throws -> [Float] {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        return try embedSynchronously(
            try aligner.alignedFace(face, in: source, orientation: frame.orientation))
    }

    /// Synchronous body so CoreML's blocking `prediction(from:)` runs on this actor's executor
    /// (never the main actor) and the non-Sendable model never crosses an isolation boundary.
    private func embedSynchronously(_ crop: AlignedFace) throws -> [Float] {
        let value: MLFeatureValue
        switch inputKind {
        case .image:
            value = MLFeatureValue(pixelBuffer: try Self.pixelBuffer(from: crop))
        case .tensor(let shape):
            value = MLFeatureValue(
                multiArray: try Self.tensor(from: crop, shape: shape, preprocessing: preprocessing))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
            throw HaloVisionError.unsupportedModel("output \(outputName) is not a multi-array")
        }
        let raw = MLShapedArray<Float>(converting: array).scalars
        guard raw.count == space.dimension else {
            throw HaloVisionError.dimensionMismatch(expected: space.dimension, actual: raw.count)
        }
        return try EmbeddingMath.l2Normalized(raw)
    }

    // MARK: - Model I/O

    struct ModelIO: Equatable {
        var inputName: String
        var inputKind: InputKind
        var outputName: String
        var dimension: Int
    }

    static func inspect(_ description: MLModelDescription) throws -> ModelIO {
        let side = FaceAligner.outputSize
        let inputs = description.inputDescriptionsByName.sorted { $0.key < $1.key }
        guard inputs.count == 1, let (inputName, input) = inputs.first else {
            throw HaloVisionError.unsupportedModel("expected exactly one input, found \(inputs.count)")
        }
        let kind: InputKind
        switch input.type {
        case .image:
            guard let c = input.imageConstraint, c.pixelsWide == side, c.pixelsHigh == side else {
                throw HaloVisionError.unsupportedModel("image input must be \(side)x\(side)")
            }
            kind = .image
        case .multiArray:
            guard let c = input.multiArrayConstraint else {
                throw HaloVisionError.unsupportedModel("tensor input has no shape")
            }
            let shape = c.shape.map(\.intValue)
            guard shape == [1, 3, side, side] || shape == [3, side, side] else {
                throw HaloVisionError.unsupportedModel(
                    "tensor input shape \(shape) is not [1,3,\(side),\(side)]")
            }
            guard c.dataType == .float32 else {
                throw HaloVisionError.unsupportedModel("tensor input must be float32")
            }
            kind = .tensor(shape: shape)
        default:
            throw HaloVisionError.unsupportedModel("input must be an image or a tensor")
        }

        let outputs = description.outputDescriptionsByName
            .filter { $0.value.type == .multiArray }
            .sorted { $0.key < $1.key }
        guard outputs.count == 1, let (outputName, output) = outputs.first,
            let outputShape = output.multiArrayConstraint?.shape.map(\.intValue)
        else {
            throw HaloVisionError.unsupportedModel("expected exactly one tensor output")
        }
        let dimension = outputShape.reduce(1, *)
        guard dimension > 0, outputShape.filter({ $0 > 1 }).count == 1 else {
            throw HaloVisionError.unsupportedModel("output shape \(outputShape) is not a vector")
        }
        return ModelIO(inputName: inputName, inputKind: kind, outputName: outputName, dimension: dimension)
    }

    // MARK: - Preprocessing (pure, testable)

    /// Planar float tensor (`[1, 3, H, W]` or `[3, H, W]`) from an aligned crop.
    static func tensor(from crop: AlignedFace, shape: [Int], preprocessing: Preprocessing) throws
        -> MLMultiArray
    {
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        } catch {
            throw HaloVisionError.preprocessingFailed
        }
        let channels: [Int] = preprocessing.channelOrder == .rgb ? [0, 1, 2] : [2, 1, 0]
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            // Last three dims are C, H, W regardless of a leading batch dimension.
            let cStride = strides[strides.count - 3]
            let yStride = strides[strides.count - 2]
            let xStride = strides[strides.count - 1]
            for y in 0..<crop.height {
                for x in 0..<crop.width {
                    let p = (y * crop.width + x) * 4
                    for (c, source) in channels.enumerated() {
                        let v = Float(crop.rgbx[p + source])
                        buffer[c * cStride + y * yStride + x * xStride] =
                            (v - preprocessing.mean) * preprocessing.scale
                    }
                }
            }
        }
        return array
    }

    /// 32BGRA pixel buffer for image-input models (their normalization is baked into the model).
    static func pixelBuffer(from crop: AlignedFace) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, crop.width, crop.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw HaloVisionError.preprocessingFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw HaloVisionError.preprocessingFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let s = (y * crop.width + x) * 4
                let d = y * bytesPerRow + x * 4
                destination[d] = crop.rgbx[s + 2]
                destination[d + 1] = crop.rgbx[s + 1]
                destination[d + 2] = crop.rgbx[s]
                destination[d + 3] = 255
            }
        }
        return buffer
    }
}
