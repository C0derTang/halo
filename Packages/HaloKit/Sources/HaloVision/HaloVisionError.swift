import Foundation

/// Typed failures from HaloVision. The app maps the model-provisioning cases to a
/// "recognition unavailable" state; none of them should ever crash the app.
///
/// Cases never carry pixels or vectors (biometrics stay out of errors, logs and crash reports).
public enum HaloVisionError: Error, Equatable, Sendable {
    /// No compiled model exists at the given location (e.g. `scripts/fetch-models.sh` never ran).
    case modelNotFound(URL)
    /// The URL points at an uncompiled `.mlmodel` / `.mlpackage`; a compiled `.mlmodelc` is required.
    case modelNotCompiled(URL)
    /// CoreML refused to load the model. Carries CoreML's description only.
    case modelLoadFailed(String)
    /// The model's inputs/outputs are not a 112x112 face crop -> embedding vector.
    case unsupportedModel(String)
    /// Rendering the aligned crop or building the model input failed.
    case preprocessingFailed
    /// The model produced a vector of an unexpected length.
    case dimensionMismatch(expected: Int, actual: Int)
    /// The embedding has zero or non-finite norm and cannot be normalized.
    case degenerateEmbedding

    /// True when the embedder cannot be used at all and the app should show
    /// "recognition unavailable" instead of retrying per face.
    public var isRecognitionUnavailable: Bool {
        switch self {
        case .modelNotFound, .modelNotCompiled, .modelLoadFailed, .unsupportedModel: true
        case .preprocessingFailed, .dimensionMismatch, .degenerateEmbedding: false
        }
    }
}
