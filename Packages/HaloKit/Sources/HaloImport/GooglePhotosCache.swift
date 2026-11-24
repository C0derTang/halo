import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-device cache of the photos picked in Google Photos, kept only so the enrollment UI can crop
/// face thumbnails. Each photo is re-encoded as an upright JPEG with the long edge <= `maxPixelSize`
/// and no metadata (no GPS / EXIF is copied).
///
/// - Directory: `Application Support/GooglePhotos/`, excluded from backup. On iOS the directory and
///   every file use `FileProtectionType.complete` (unreadable while the device is locked).
/// - File name: SHA-256 of the media item id. The Google filename is never used.
/// - `removeAll()` is the kill switch (`GooglePhotosImporting.eraseAll()`).
///
/// Synchronous file and decode work: call it off the main actor (invariant 7). The importer calls
/// it from its own actor.
public struct GooglePhotosCache: Sendable {
    public static let sourceRefPrefix = "gphotos:"

    public let directory: URL
    public let maxPixelSize: Int

    public init(directory: URL, maxPixelSize: Int = 2048) {
        self.directory = directory
        self.maxPixelSize = maxPixelSize
    }

    /// `Application Support/GooglePhotos/` of the current app container.
    public static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "GooglePhotos", directoryHint: .isDirectory)
    }

    /// The media item id in a `.googlePhotos` embedding's `sourceRef`, or nil for other refs.
    public static func itemID(fromSourceRef sourceRef: String) -> String? {
        guard sourceRef.hasPrefix(sourceRefPrefix) else { return nil }
        let id = String(sourceRef.dropFirst(sourceRefPrefix.count))
        return id.isEmpty ? nil : id
    }

    func fileURL(forItemID id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".jpg", directoryHint: .notDirectory)
    }

    public func contains(itemID id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forItemID: id).path(percentEncoded: false))
    }

    /// Decodes downloaded bytes, uprights + downscales them, and stores them as a protected JPEG.
    /// Returns false (and stores nothing) when the bytes are not a decodable image.
    @discardableResult
    public func store(_ data: Data, forItemID id: String) throws -> Bool {
        guard let image = Self.uprightImage(from: data, maxPixelSize: maxPixelSize),
            let jpeg = Self.jpeg(image)
        else { return false }
        try ensureDirectory()
        var url = fileURL(forItemID: id)
        #if os(iOS)
            try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        #else
            try jpeg.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return true
    }

    /// The cached photo for an item (upright), downscaled to `maxPixelSize` when given.
    public func image(forItemID id: String, maxPixelSize: Int? = nil) -> CGImage? {
        guard let data = try? Data(contentsOf: fileURL(forItemID: id)) else { return nil }
        return Self.uprightImage(from: data, maxPixelSize: maxPixelSize ?? self.maxPixelSize)
    }

    /// The cached photo for a `.googlePhotos` embedding's `sourceRef` (upright), or nil.
    public func image(forSourceRef sourceRef: String) -> CGImage? {
        guard let id = Self.itemID(fromSourceRef: sourceRef) else { return nil }
        return image(forItemID: id)
    }

    public func remove(itemID id: String) throws {
        let url = fileURL(forItemID: id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes every cached photo whose item is not in `keeping` (e.g. faces the user rejected or
    /// people they forgot), so a photo is only kept while it still backs an embedding.
    public func prune(keepingItemIDs keeping: Set<String>) throws {
        let kept = Set(keeping.map { fileURL(forItemID: $0).lastPathComponent })
        for url in try cachedFiles() where !kept.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every cached photo and the directory itself.
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func cachedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        let path = directory.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
            let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: attributes)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }

    /// Decodes with ImageIO, applying the EXIF orientation and bounding the long edge.
    static func uprightImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
