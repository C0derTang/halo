import CoreGraphics
import CoreML
import Foundation
import HaloCore
import Testing

@testable import HaloVision

@Suite struct L2NormalizationTests {
    @Test func normalizesToUnitLength() throws {
        let v = try EmbeddingMath.l2Normalized([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-6)
        #expect(abs(v[1] - 0.8) < 1e-6)
    }

    @Test func highDimensionalVectorHasUnitNorm() throws {
        let raw = (0..<512).map { Float(sin(Double($0) * 0.37)) * 40 }
        let v = try EmbeddingMath.l2Normalized(raw)
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        #expect(abs(norm - 1) < 1e-5)
        // Direction preserved.
        #expect(v[1] > 0 && raw[1] > 0)
    }

    @Test func alreadyNormalizedIsUnchanged() throws {
        let unit: [Float] = [0, 1, 0]
        #expect(try EmbeddingMath.l2Normalized(unit) == unit)
    }

    @Test(arguments: [[Float](), [0, 0, 0], [Float.nan, 1], [Float.infinity, 0]])
    func degenerateVectorsThrow(vector: [Float]) {
        #expect(throws: HaloVisionError.degenerateEmbedding) {
            try EmbeddingMath.l2Normalized(vector)
        }
    }
}

@Suite struct ModelProvisioningTests {
    @Test func missingModelThrowsTypedError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-missing-\(UUID().uuidString).mlmodelc")
        #expect(throws: HaloVisionError.modelNotFound(url)) {
            try CoreMLFaceEmbedder(compiledModelAt: url)
        }
    }

    @Test func missingModelInDirectoryThrowsTypedError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "halo-empty-\(UUID().uuidString)")
        let error = #expect(throws: HaloVisionError.self) { try CoreMLFaceEmbedder(directory: dir) }
        #expect(error?.isRecognitionUnavailable == true)
        guard case .modelNotFound(let url) = error else {
            Issue.record("expected modelNotFound, got \(String(describing: error))")
            return
        }
        #expect(url.lastPathComponent == "HaloFaceEmbedder.mlmodelc")
    }

    @Test func uncompiledModelThrowsTypedError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-\(UUID().uuidString).mlpackage")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: HaloVisionError.modelNotCompiled(url)) {
            try CoreMLFaceEmbedder(compiledModelAt: url)
        }
    }

    @Test func corruptCompiledModelThrowsLoadFailure() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-corrupt-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = #expect(throws: HaloVisionError.self) { try CoreMLFaceEmbedder(compiledModelAt: url) }
        guard case .modelLoadFailed = error else {
            Issue.record("expected modelLoadFailed, got \(String(describing: error))")
            return
        }
        #expect(error?.isRecognitionUnavailable == true)
    }

    @Test func perFaceFailuresDoNotMeanUnavailable() {
        #expect(!HaloVisionError.degenerateEmbedding.isRecognitionUnavailable)
        #expect(!HaloVisionError.dimensionMismatch(expected: 512, actual: 128).isRecognitionUnavailable)
    }
}

@Suite struct EmbedderPreprocessingTests {
    private func crop(r: UInt8, g: UInt8, b: UInt8) -> AlignedFace {
        let side = FaceAligner.outputSize
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
        }
        return AlignedFace(width: side, height: side, rgbx: bytes)
    }

    @Test func tensorIsPlanarRGBNormalizedForArcFace() throws {
        let array = try CoreMLFaceEmbedder.tensor(
            from: crop(r: 255, g: 0, b: 127), shape: [1, 3, 112, 112], preprocessing: .arcFace)
        let values = MLShapedArray<Float>(converting: array)
        #expect(values.shape == [1, 3, 112, 112])
        #expect(abs(values[0, 0, 5, 7].scalar! - 1) < 1e-6)  // R: (255 - 127.5) / 127.5
        #expect(abs(values[0, 1, 5, 7].scalar! + 1) < 1e-6)  // G: (0 - 127.5) / 127.5
        #expect(abs(values[0, 2, 111, 111].scalar! - (-0.5 / 127.5)) < 1e-6)  // B: 127
    }

    @Test func bgrOrderSwapsChannelPlanes() throws {
        let bgr = CoreMLFaceEmbedder.Preprocessing(mean: 0, scale: 1, channelOrder: .bgr)
        let array = try CoreMLFaceEmbedder.tensor(
            from: crop(r: 10, g: 20, b: 30), shape: [3, 112, 112], preprocessing: bgr)
        let values = MLShapedArray<Float>(converting: array)
        #expect(values[0, 0, 0].scalar == 30)
        #expect(values[1, 0, 0].scalar == 20)
        #expect(values[2, 0, 0].scalar == 10)
    }

    @Test func pixelBufferIsBGRA() throws {
        let buffer = try CoreMLFaceEmbedder.pixelBuffer(from: crop(r: 10, g: 20, b: 30))
        #expect(CVPixelBufferGetWidth(buffer) == 112)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        #expect([base[0], base[1], base[2], base[3]] == [30, 20, 10, 255])
    }
}

/// Runs only when `scripts/fetch-models.sh` has produced the real model (never in CI: weights are
/// not committed). Exercises the full align -> CoreML -> L2 path on a synthetic image.
@Suite(.enabled(if: FetchedModel.url != nil, "run scripts/fetch-models.sh to enable"))
struct FetchedModelTests {
    @Test func embedsSyntheticCropAsUnitVector() async throws {
        let url = try #require(FetchedModel.url)
        let embedder = try CoreMLFaceEmbedder(compiledModelAt: url)
        #expect(embedder.space == EmbeddingSpace(modelID: CoreMLFaceEmbedder.defaultModelID, dimension: 512))
        let image = try SyntheticImage.quadrants(side: 224)
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), quality: 1, timestamp: 0)
        let vector = try await embedder.embed(face: face, in: image)
        #expect(vector.count == 512)
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        #expect(abs(norm - 1) < 1e-4)
        // Deterministic for identical input.
        #expect(try await embedder.embed(face: face, in: image) == vector)
    }
}

enum FetchedModel {
    /// `<repo>/Models/HaloFaceEmbedder.mlmodelc`, located relative to this source file.
    static let url: URL? = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent("Models/HaloFaceEmbedder.mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()
}
