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

#if canImport(Photos)
    /// `PhotoLibrarySource` over the user's Apple Photos library (PhotoKit).
    ///
    /// The app must obtain Photos read authorization before scanning. Only image assets with a
    /// creation date are enumerated. Pixels come only from what is already on the device:
    /// `requestImage` with `isNetworkAccessAllowed = false` returns the best local rendition (with
    /// "Optimize iPhone Storage" that is usually a local derivative rather than the full original).
    /// When nothing usable is local the asset loads as nil and the scan skips it; it is never
    /// downloaded (no network, invariant 2). Nothing here writes to the library.
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
            let once = ResumeOnce()
            return await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(
                    for: phAsset, targetSize: target, contentMode: .aspectFit, options: options
                ) { image, info in
                    // `.highQualityFormat` delivers once; ignore a degraded pass defensively.
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    let loaded = image.flatMap(Self.scanImage)
                    if once.claim() { continuation.resume(returning: loaded) }
                }
            }
        }

        /// Local-only request: never downloads from iCloud (invariant 2); unavailable -> nil image.
        static func requestOptions() -> PHImageRequestOptions {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.deliveryMode = .highQualityFormat
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

    /// Guards a continuation against a second PhotoKit callback.
    private final class ResumeOnce: Sendable {
        private let done = Mutex(false)
        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }
#endif
