import CoreGraphics
import Foundation
import ImageIO

/// One photo-library asset as the scan sees it: its stable id plus its position in scan order.
///
/// Scan order is newest-first: `creationDate` descending, ties broken by `localIdentifier`
/// ascending, so the order is total and a position can be resumed from exactly.
public struct PhotoAsset: Hashable, Codable, Sendable {
    /// `PHAsset.localIdentifier`. Stored as the embedding's `sourceRef`.
    public var localIdentifier: String
    public var creationDate: Date

    public init(localIdentifier: String, creationDate: Date) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
    }

    /// True when `self` is scanned before `other` (newer, or same date with a smaller identifier).
    public func precedes(_ other: PhotoAsset) -> Bool {
        if creationDate != other.creationDate { return creationDate > other.creationDate }
        return localIdentifier < other.localIdentifier
    }
}

/// A decoded, downscaled photo. `image` holds the raw (un-rotated) pixels; `orientation` says how to
/// make them upright.
public struct PhotoScanImage: Sendable {
    public var image: CGImage
    public var orientation: CGImagePropertyOrientation

    public init(image: CGImage, orientation: CGImagePropertyOrientation = .up) {
        self.image = image
        self.orientation = orientation
    }
}

/// Read-only access to the on-device photo library for the face scan.
///
/// Implementations never download from the network: an asset whose pixels are not on the device
/// (e.g. iCloud-only) loads as `nil` and the scan skips it (invariants 2 + 3).
public protocol PhotoLibrarySource: Sendable {
    /// Up to `limit` image assets strictly after `position` in scan order (newest-first), or from
    /// the newest asset when `position` is nil. An empty result means the library is exhausted.
    func assets(after position: PhotoAsset?, limit: Int) async throws -> [PhotoAsset]

    /// The asset's best locally available pixels, downscaled so the long edge is about
    /// `maxPixelSize`, or nil when nothing usable is on the device (the scan skips the asset).
    /// Never touches the network.
    func loadImage(for asset: PhotoAsset, maxPixelSize: Int) async throws -> PhotoScanImage?
}

/// Paging over a creation-date-descending sequence whose ties are in arbitrary order (what
/// PhotoKit returns for a `creationDate` sort). Pure, so the PhotoKit source's paging is testable.
enum PhotoScanPaging {
    /// Returns up to `limit` assets strictly after `position` in scan order.
    ///
    /// - Parameters:
    ///   - count: number of assets in the sequence.
    ///   - asset: accessor for index `0..<count`; the sequence is sorted by `creationDate`
    ///     descending, with ties in any order.
    static func page(
        count: Int, asset: (Int) -> PhotoAsset, after position: PhotoAsset?, limit: Int
    ) -> [PhotoAsset] {
        guard limit > 0 else { return [] }
        var collected: [PhotoAsset] = []
        var boundaryDate: Date?
        for index in 0..<count {
            let candidate = asset(index)
            // Once `limit` assets are in hand, finish their last date's tie group, then stop: every
            // later asset is strictly older and therefore sorts after all collected ones.
            if let boundaryDate, candidate.creationDate < boundaryDate { break }
            if let position, !position.precedes(candidate) { continue }
            collected.append(candidate)
            if collected.count == limit { boundaryDate = candidate.creationDate }
        }
        collected.sort { $0.precedes($1) }
        return Array(collected.prefix(limit))
    }
}

/// In-memory `PhotoLibrarySource` for tests and previews. Holds synthetic images only.
public actor InMemoryPhotoLibrary: PhotoLibrarySource {
    /// Creation-date descending; ties deliberately in reverse identifier order so callers exercise
    /// the same tie handling PhotoKit needs.
    private var entries: [(asset: PhotoAsset, image: PhotoScanImage?)] = []
    /// Identifiers passed to `loadImage`, in call order.
    public private(set) var loadedIdentifiers: [String] = []

    /// - Parameter assets: each asset with its image, or nil to model an iCloud-only asset.
    public init(_ assets: [(PhotoAsset, PhotoScanImage?)] = []) {
        entries = Self.sorted(assets.map { (asset: $0.0, image: $0.1) })
    }

    /// Adds assets (e.g. photos taken after a scan).
    public func add(_ assets: [(PhotoAsset, PhotoScanImage?)]) {
        entries = Self.sorted(entries + assets.map { (asset: $0.0, image: $0.1) })
    }

    public func assets(after position: PhotoAsset?, limit: Int) async throws -> [PhotoAsset] {
        PhotoScanPaging.page(
            count: entries.count, asset: { entries[$0].asset }, after: position, limit: limit)
    }

    public func loadImage(for asset: PhotoAsset, maxPixelSize: Int) async throws -> PhotoScanImage? {
        loadedIdentifiers.append(asset.localIdentifier)
        return entries.first { $0.asset.localIdentifier == asset.localIdentifier }?.image
    }

    private static func sorted(_ entries: [(asset: PhotoAsset, image: PhotoScanImage?)])
        -> [(asset: PhotoAsset, image: PhotoScanImage?)]
    {
        entries.sorted {
            $0.asset.creationDate != $1.asset.creationDate
                ? $0.asset.creationDate > $1.asset.creationDate
                : $0.asset.localIdentifier > $1.asset.localIdentifier
        }
    }
}
