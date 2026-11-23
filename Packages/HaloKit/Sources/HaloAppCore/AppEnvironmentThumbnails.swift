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
            let once = ThumbnailResumeOnce()
            let timeout = self.timeout
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<SendableImage, Never>) in
                let request = PHImageManager.default().requestImage(
                    for: asset, targetSize: size, contentMode: .aspectFill, options: options
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if once.claim() {
                        continuation.resume(returning: SendableImage(image.flatMap(Self.cgImage)))
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    if once.claim() {
                        PHImageManager.default().cancelImageRequest(request)
                        continuation.resume(returning: SendableImage(nil))
                    }
                }
            }.image
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

    /// Guards the continuation against a second callback or the timeout firing after a result.
    private final class ThumbnailResumeOnce: Sendable {
        private let done = Mutex(false)
        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }
#endif
