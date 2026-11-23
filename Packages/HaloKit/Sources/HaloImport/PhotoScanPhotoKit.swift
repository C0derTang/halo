import CoreGraphics
import Foundation
import ImageIO
import Synchronization

#if canImport(Photos)
    import Photos
#endif
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Sizing for the scan's image requests.
enum PhotoScanImageSizing {
    /// Aspect-fit target whose long edge is `maxPixelSize`, never larger than the original.
    /// Unknown dimensions fall back to a `maxPixelSize` square (aspect-fit keeps the ratio).
    static func targetSize(pixelWidth: Int, pixelHeight: Int, maxPixelSize: Int) -> CGSize {
        let limit = max(maxPixelSize, 1)
        guard pixelWidth > 0, pixelHeight > 0 else { return CGSize(width: limit, height: limit) }
        let scale = min(1, Double(limit) / Double(max(pixelWidth, pixelHeight)))
        return CGSize(
            width: max(1, (Double(pixelWidth) * scale).rounded()),
            height: max(1, (Double(pixelHeight) * scale).rounded()))
    }
}

/// Turns a callback-style image request into one awaited result that cannot hang.
///
/// Delivery rules (PhotoKit `.opportunistic`: a degraded preview may come first, then a final
/// image): degraded deliveries are ignored; the first non-degraded delivery resolves the load, with
/// nil if it carries no image (unavailable locally, failed or cancelled). If no final delivery
/// arrives within `timeout` (a degraded-only or never-called handler) the load resolves nil and the
/// request is cancelled. Task cancellation also resolves nil and cancels the request.
enum PhotoScanImageRequest {
    /// Starts a request, calls `deliver(image, isDegraded)` for each delivery, and returns a cancel.
    typealias Start =
        (_ deliver: @escaping @Sendable (PhotoScanImage?, Bool) -> Void)
        -> @Sendable () -> Void

    /// Default wait for a final delivery.
    static let defaultTimeout: Duration = .seconds(10)

    static func load(timeout: Duration = defaultTimeout, start: Start) async -> PhotoScanImage? {
        let resolver = Resolver()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolver.install(continuation)
                let timer = Task {
                    try await Task.sleep(for: timeout)
                    resolver.finish(nil)
                }
                resolver.onFinish { timer.cancel() }
                let cancel = start { image, isDegraded in
                    if isDegraded { return }
                    resolver.finish(image)
                }
                resolver.setCancel(cancel)
            }
        } onCancel: {
            resolver.finish(nil)
        }
    }

    private final class Resolver: Sendable {
        private struct State {
            var continuation: CheckedContinuation<PhotoScanImage?, Never>?
            var cancel: (@Sendable () -> Void)?
            var cleanup: (@Sendable () -> Void)?
            var done = false
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<PhotoScanImage?, Never>) {
            // Cancellation can win the race before the continuation exists.
            let alreadyDone = state.withLock { state -> Bool in
                if state.done { return true }
                state.continuation = continuation
                return false
            }
            if alreadyDone { continuation.resume(returning: nil) }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.done { return true }
                state.cleanup = cleanup
                return false
            }
            if runNow { cleanup() }
        }

        func setCancel(_ cancel: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.done { return true }
                state.cancel = cancel
                return false
            }
            if runNow { cancel() }
        }

        /// First call wins; later deliveries, the timeout and cancellation are no-ops.
        func finish(_ image: PhotoScanImage?) {
            let (continuation, cancel, cleanup) = state.withLock {
                state -> (
                    CheckedContinuation<PhotoScanImage?, Never>?, (@Sendable () -> Void)?,
                    (@Sendable () -> Void)?
                ) in
                if state.done { return (nil, nil, nil) }
                state.done = true
                defer {
                    state.continuation = nil
                    state.cancel = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cancel, state.cleanup)
            }
            cleanup?()
            // Cancelling after a final image is harmless; after a timeout it frees PhotoKit's work.
            cancel?()
            continuation?.resume(returning: image)
        }
    }
}

#if canImport(Photos)
    /// `PhotoLibrarySource` over the user's Apple Photos library (PhotoKit).
    ///
    /// The app must obtain Photos read authorization before scanning. Only image assets with a
    /// creation date are enumerated. Pixels come only from what is already on the device:
    /// `requestImage` with `isNetworkAccessAllowed = false` returns the best local rendition (with
    /// "Optimize iPhone Storage" that is usually a local derivative rather than the full original).
    /// Requests are `.opportunistic`: PhotoKit may first deliver a degraded preview (ignored), then a
    /// final image, which with the network off is the best rendition already on the device (a
    /// smaller local derivative counts; `.highQualityFormat` could return nil for it). A request that
    /// never delivers a final image times out (10 s) and loads as nil.
    ///
    /// When nothing usable is local the asset loads as nil and the scan skips it (counted in
    /// `assetsUnavailable`); it is never downloaded (no network, invariant 2). The scan cursor moves
    /// past such assets and a completed pass does not revisit them: an asset whose pixels become
    /// local later is picked up only if a future pass reaches it as new (it is then ordered by
    /// creation date, so an old photo is not). Nothing here writes to the library.
    public struct PhotoKitLibrarySource: PhotoLibrarySource {
        public init() {}

        @concurrent
        public func assets(after position: PhotoAsset?, limit: Int) async throws -> [PhotoAsset] {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            var predicates = [
                NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
                NSPredicate(format: "creationDate != nil"),
            ]
            if let position {
                // Inclusive: assets sharing the cursor's date are ordered by identifier in paging.
                predicates.append(NSPredicate(format: "creationDate <= %@", position.creationDate as NSDate))
            }
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let result = PHAsset.fetchAssets(with: options)
            return PhotoScanPaging.page(
                count: result.count,
                asset: { index in
                    let asset = result.object(at: index)
                    return PhotoAsset(
                        localIdentifier: asset.localIdentifier,
                        creationDate: asset.creationDate ?? .distantPast)
                }, after: position, limit: limit)
        }

        @concurrent
        public func loadImage(for asset: PhotoAsset, maxPixelSize: Int) async throws -> PhotoScanImage? {
            guard
                let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
                    .firstObject
            else { return nil }
            let target = PhotoScanImageSizing.targetSize(
                pixelWidth: phAsset.pixelWidth, pixelHeight: phAsset.pixelHeight, maxPixelSize: maxPixelSize)
            let options = Self.requestOptions()
            return await PhotoScanImageRequest.load { deliver in
                let id = PHImageManager.default().requestImage(
                    for: phAsset, targetSize: target, contentMode: .aspectFit, options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    deliver(image.flatMap(Self.scanImage), degraded)
                }
                return { PHImageManager.default().cancelImageRequest(id) }
            }
        }

        /// Local-only request: never downloads from iCloud (invariant 2); unavailable -> nil image.
        static func requestOptions() -> PHImageRequestOptions {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            return options
        }

        #if canImport(UIKit)
            /// The backing pixels plus the orientation that makes them upright (the uprighter applies
            /// it; `.up` is a no-op).
            static func scanImage(_ image: UIImage) -> PhotoScanImage? {
                guard let cgImage = image.cgImage else { return nil }
                return PhotoScanImage(image: cgImage, orientation: orientation(image.imageOrientation))
            }

            static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
                switch o {
                case .up: .up
                case .down: .down
                case .left: .left
                case .right: .right
                case .upMirrored: .upMirrored
                case .downMirrored: .downMirrored
                case .leftMirrored: .leftMirrored
                case .rightMirrored: .rightMirrored
                @unknown default: .up
                }
            }
        #elseif canImport(AppKit)
            /// AppKit renders the image upright, so the orientation is `.up`.
            static func scanImage(_ image: NSImage) -> PhotoScanImage? {
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return nil
                }
                return PhotoScanImage(image: cgImage, orientation: .up)
            }
        #endif
    }
#endif
