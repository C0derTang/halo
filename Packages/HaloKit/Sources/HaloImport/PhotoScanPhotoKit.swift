import CoreGraphics
import Foundation
import ImageIO

#if canImport(Photos)
    import Photos
#endif

/// Decodes encoded image data into a downscaled `CGImage` without applying its orientation.
enum PhotoScanImageDecoding {
    /// Thumbnail of the first image in `data` whose long edge is at most `maxPixelSize`, with the
    /// raw (un-rotated) pixels. Nil when the data is not a decodable image.
    static func downscaled(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                // The orientation travels separately; the scan uprights once for detect + embed.
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

#if canImport(Photos)
    /// `PhotoLibrarySource` over the user's Apple Photos library (PhotoKit).
    ///
    /// The app must obtain Photos read authorization before scanning. Only image assets with a
    /// creation date are enumerated. Pixels come from what is already on the device:
    /// `isNetworkAccessAllowed` is always false, so iCloud-only assets load as nil and are skipped
    /// (no network, invariant 2). Nothing here writes to the library.
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
            let options = Self.requestOptions()
            let loaded: (Data, CGImagePropertyOrientation)? = await withCheckedContinuation { continuation in
                // Data requests call the handler exactly once (no degraded pass).
                PHImageManager.default().requestImageDataAndOrientation(for: phAsset, options: options) {
                    data, _, orientation, _ in
                    continuation.resume(returning: data.map { ($0, orientation) })
                }
            }
            guard let (data, orientation) = loaded,
                let image = PhotoScanImageDecoding.downscaled(data, maxPixelSize: maxPixelSize)
            else { return nil }
            return PhotoScanImage(image: image, orientation: orientation)
        }

        /// Local-only request: never downloads from iCloud (invariant 2); unavailable -> nil data.
        static func requestOptions() -> PHImageRequestOptions {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            return options
        }
    }
#endif
