import CoreGraphics
import CoreImage
import Foundation
import HaloCore
import ImageIO

/// Crops an enrollment / People thumbnail to the face (`FaceEmbedding.faceBox`) with padding.
/// Pure geometry on in-memory images (invariant 2: nothing is written anywhere).
public enum FaceThumbnailCrop {
    /// Margin around the face on each side, as a fraction of the face box's longer side, so the
    /// crop shows the head and a little context.
    public static let padding: CGFloat = 0.5

    /// The box if it is usable: finite, non-empty, and overlapping the unit square.
    static func validated(_ box: CGRect) -> CGRect? {
        guard box.origin.x.isFinite, box.origin.y.isFinite, box.width.isFinite, box.height.isFinite,
            box.width > 0, box.height > 0,
            box.intersects(CGRect(x: 0, y: 0, width: 1, height: 1))
        else { return nil }
        return box
    }

    /// Long edge to request the whole photo at, so the padded face crop comes out about `target`
    /// pixels. Capped at `cap`, never below `target`.
    static func sourcePixelSize(faceBox: CGRect, target: CGFloat, cap: CGFloat) -> CGFloat {
        let fraction = max(faceBox.width, faceBox.height) * (1 + 2 * padding)
        guard fraction > 0 else { return target }
        return max(target, min(cap, (target / min(fraction, 1)).rounded(.up)))
    }

    /// Pixel rect (top-left origin, as `CGImage.cropping(to:)` expects) of a square around the face:
    /// centred on it, `padding` added on every side, shifted to stay inside the image and shrunk only
    /// when the image is smaller than the square. nil when the box does not overlap the image.
    static func cropRect(faceBox: CGRect, width: Int, height: Int) -> CGRect? {
        guard let box = validated(faceBox), width > 0, height > 0 else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        let face = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
        let side = min(max(face.width, face.height) * (1 + 2 * padding), w, h)
        let x = min(max(face.midX - side / 2, 0), w - side)
        let y = min(max(face.midY - side / 2, 0), h - side)
        let rect = CGRect(x: x, y: y, width: side, height: side).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    /// The face crop of an UPRIGHT image, or the whole image when there is no usable box.
    static func crop(_ image: CGImage, to faceBox: CGRect?) -> CGImage {
        guard let faceBox, let rect = cropRect(faceBox: faceBox, width: image.width, height: image.height),
            let cropped = image.cropping(to: rect)
        else { return image }
        return cropped
    }

    /// `image` turned upright (the face box is in upright coordinates). `.up` is returned as is.
    static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return SharedCIContext.shared.context.createCGImage(oriented, from: oriented.extent)
    }
}

/// `CIContext` is thread-safe; one is shared because creating them is expensive.
private struct SharedCIContext: @unchecked Sendable {
    static let shared = SharedCIContext()
    let context = CIContext()
}

#if canImport(Photos)
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
    /// When the embedding has a `faceBox`, the thumbnail is that face with padding (see
    /// `FaceThumbnailCrop`), cropped from a photo requested just large enough for the crop to be
    /// about `targetPixelSize`. Without one (embeddings stored before the field existed) it is the
    /// whole photo, aspect-filled to `targetPixelSize`. Either way the result is upright.
    public struct PhotoKitThumbnailProvider: FaceThumbnailProvider {
        public var targetPixelSize: CGFloat
        /// Long edge cap for the photo requested to crop a face from.
        public var maxSourcePixelSize: CGFloat
        /// A PhotoKit request that never calls back resolves to nil after this long.
        public var timeout: Duration

        public init(
            targetPixelSize: CGFloat = 320, maxSourcePixelSize: CGFloat = 2048,
            timeout: Duration = .seconds(10)
        ) {
            self.targetPixelSize = targetPixelSize
            self.maxSourcePixelSize = maxSourcePixelSize
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
            let faceBox = embedding.faceBox.flatMap(FaceThumbnailCrop.validated)
            let side =
                faceBox.map {
                    FaceThumbnailCrop.sourcePixelSize(
                        faceBox: $0, target: targetPixelSize, cap: maxSourcePixelSize)
                } ?? targetPixelSize
            let size = CGSize(width: side, height: side)
            // With a face box the whole photo is needed (aspect-fit), so the normalized box applies.
            let contentMode: PHImageContentMode = faceBox == nil ? .aspectFill : .aspectFit
            let request = ThumbnailRequest()
            let timeout = self.timeout
            let photo = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<SendableImage, Never>) in
                    guard request.install(continuation) else { return }  // already cancelled
                    let id = PHImageManager.default().requestImage(
                        for: asset, targetSize: size, contentMode: contentMode, options: options
                    ) { image, info in
                        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                        request.finish(
                            SendableImage(
                                image.flatMap(Self.cgImage), orientation: image.map(Self.orientation) ?? .up))
                    }
                    request.setRequestID(id)
                    request.setTimer(
                        Task {
                            try? await Task.sleep(for: timeout)
                            guard !Task.isCancelled else { return }
                            request.cancel()  // PhotoKit never called back
                        })
                }
            } onCancel: {
                request.cancel()
            }
            // Off the main actor (`@concurrent`): orient and crop after PhotoKit's callback.
            guard let raw = photo.image,
                let upright = FaceThumbnailCrop.upright(raw, orientation: photo.orientation)
            else { return nil }
            return FaceThumbnailCrop.crop(upright, to: faceBox)
        }

        #if canImport(UIKit)
            static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
            /// `UIImage.cgImage` keeps the stored pixel orientation; this says how to make it upright.
            static func orientation(_ image: UIImage) -> CGImagePropertyOrientation {
                switch image.imageOrientation {
                case .up: .up
                case .upMirrored: .upMirrored
                case .down: .down
                case .downMirrored: .downMirrored
                case .left: .left
                case .leftMirrored: .leftMirrored
                case .right: .right
                case .rightMirrored: .rightMirrored
                @unknown default: .up
                }
            }
        #elseif canImport(AppKit)
            static func cgImage(_ image: NSImage) -> CGImage? {
                image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            static func orientation(_ image: NSImage) -> CGImagePropertyOrientation { .up }
        #endif
    }

    /// `CGImage` is immutable once created; this carries one out of the PhotoKit callback.
    private struct SendableImage: @unchecked Sendable {
        let image: CGImage?
        let orientation: CGImagePropertyOrientation
        init(_ image: CGImage?, orientation: CGImagePropertyOrientation = .up) {
            self.image = image
            self.orientation = orientation
        }
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
