#if canImport(Photos)
    import CoreGraphics
    import Foundation
    import HaloCore
    import HaloUI
    import Photos
    import Synchronization

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    /// Enrollment thumbnails from the user's Photos library (PhotoKit).
    ///
    /// Local only (invariant 2): `isNetworkAccessAllowed = false`, so an iCloud-only photo yields nil
    /// rather than a download. Images are returned in memory and never written anywhere. Only
    /// `.photoLibrary` embeddings have a PHAsset `sourceRef`; anything else has no thumbnail.
    ///
    /// The embedding does not store its face box, so the thumbnail is the whole photo
    /// (aspect-filled to `targetPixelSize`).
    public struct PhotoKitThumbnailProvider: FaceThumbnailProvider {
        public var targetPixelSize: CGFloat
        /// A PhotoKit request that never calls back resolves to nil after this long.
        public var timeout: Duration

        public init(targetPixelSize: CGFloat = 320, timeout: Duration = .seconds(10)) {
            self.targetPixelSize = targetPixelSize
            self.timeout = timeout
        }

        @concurrent
        public func thumbnail(for embedding: FaceEmbedding) async -> CGImage? {
            guard embedding.source == .photoLibrary, let ref = embedding.sourceRef,
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [ref], options: nil).firstObject
            else { return nil }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            let size = CGSize(width: targetPixelSize, height: targetPixelSize)
            let request = ThumbnailRequest()
            let timeout = self.timeout
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<SendableImage, Never>) in
                    guard request.install(continuation) else { return }  // already cancelled
                    let id = PHImageManager.default().requestImage(
                        for: asset, targetSize: size, contentMode: .aspectFill, options: options
                    ) { image, info in
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                        request.finish(SendableImage(image.flatMap(Self.cgImage)))
                    }
                    request.setRequestID(id)
                    request.setTimer(
                        Task {
                            try? await Task.sleep(for: timeout)
                            guard !Task.isCancelled else { return }
                            request.cancel()  // PhotoKit never called back
                        })
                }.image
            } onCancel: {
                request.cancel()
            }
        }

        #if canImport(UIKit)
            static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
        #elseif canImport(AppKit)
            static func cgImage(_ image: NSImage) -> CGImage? {
                image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        #endif
    }

    /// `CGImage` is immutable once created; this carries one out of the PhotoKit callback.
    private struct SendableImage: @unchecked Sendable {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    /// One PhotoKit thumbnail request: resumes its continuation exactly once (result, timeout or
    /// task cancellation), cancels the PhotoKit request when it did not deliver, and cancels the
    /// timeout task once a result arrived.
    private final class ThumbnailRequest: Sendable {
        private struct State {
            var continuation: CheckedContinuation<SendableImage, Never>?
            var requestID: PHImageRequestID?
            var timer: Task<Void, Never>?
            var finished = false
        }
        private let state = Mutex(State())

        /// Returns false (and resumes with nil) when the request was cancelled before it started.
        func install(_ continuation: CheckedContinuation<SendableImage, Never>) -> Bool {
            let finished = state.withLock { s in
                if !s.finished { s.continuation = continuation }
                return s.finished
            }
            if finished { continuation.resume(returning: SendableImage(nil)) }
            return !finished
        }

        func setRequestID(_ id: PHImageRequestID) {
            let finishedBeforehand = state.withLock { s in
                s.requestID = id
                return s.finished
            }
            // Cancelled between `install` and here: the request is no longer wanted.
            if finishedBeforehand { PHImageManager.default().cancelImageRequest(id) }
        }

        func setTimer(_ timer: Task<Void, Never>) {
            let finishedBeforehand = state.withLock { s in
                s.timer = timer
                return s.finished
            }
            if finishedBeforehand { timer.cancel() }
        }

        /// Delivers the result (first call wins).
        func finish(_ image: SendableImage) {
            let taken = state.withLock {
                s -> (CheckedContinuation<SendableImage, Never>?, Task<Void, Never>?) in
                guard !s.finished else { return (nil, nil) }
                s.finished = true
                defer {
                    s.continuation = nil
                    s.timer = nil
                }
                return (s.continuation, s.timer)
            }
            taken.1?.cancel()
            taken.0?.resume(returning: image)
        }

        /// Timeout or task cancellation: resume with nil and cancel the PhotoKit request.
        func cancel() {
            let id = state.withLock { s in s.finished ? nil : s.requestID }
            finish(SendableImage(nil))
            if let id { PHImageManager.default().cancelImageRequest(id) }
        }
    }
#endif
