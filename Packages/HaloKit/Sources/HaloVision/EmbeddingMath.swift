import Foundation

/// Vector helpers for embeddings.
public enum EmbeddingMath {
    /// Returns `vector / ||vector||₂`. Accumulates in Double so 512-d Float vectors normalize to
    /// unit length within Float precision.
    ///
    /// - Throws: `HaloVisionError.degenerateEmbedding` for empty, all-zero or non-finite input.
    public static func l2Normalized(_ vector: [Float]) throws -> [Float] {
        var sumOfSquares = 0.0
        for value in vector {
            let v = Double(value)
            sumOfSquares += v * v
        }
        let norm = sumOfSquares.squareRoot()
        guard !vector.isEmpty, norm.isFinite, norm > 0 else { throw HaloVisionError.degenerateEmbedding }
        return vector.map { Float(Double($0) / norm) }
    }
}
