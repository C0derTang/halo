import CoreGraphics
import Foundation
import Testing

@testable import HaloImport

private typealias G = GoogleFixture

@Suite struct GooglePhotosCacheTests {
    @Test func storesADownscaledJPEGNamedByHashExcludedFromBackup() throws {
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = GooglePhotosCache(directory: dir)
        #expect(!cache.contains(itemID: "item-1"))
        #expect(try cache.store(G.png(width: 3000, height: 1500), forItemID: "item-1"))
        #expect(cache.contains(itemID: "item-1"))

        let files = try cache.cachedFiles()
        #expect(files.count == 1)
        let name = try #require(files.first?.lastPathComponent)
        #expect(!name.contains("item-1"))
        #expect(name.count == 64 + 4 && name.hasSuffix(".jpg"))
        let stored = try Data(contentsOf: try #require(files.first))
        #expect(stored.starts(with: [0xFF, 0xD8]))  // JPEG
        #expect(
            try files.first?.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        let image = try #require(cache.image(forSourceRef: "gphotos:item-1"))
        #expect(max(image.width, image.height) == 2048)
        #expect(image.width == 2048 && image.height == 1024)
        let scanSized = try #require(cache.image(forItemID: "item-1", maxPixelSize: 1024))
        #expect(scanSized.width == 1024)
    }

    @Test func imagesAreStoredUpright() throws {
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = GooglePhotosCache(directory: dir)
        // EXIF orientation 6 (rotate 90 CW to display): the upright image is 400 x 600.
        try cache.store(G.png(width: 600, height: 400, orientation: 6), forItemID: "rot")
        let image = try #require(cache.image(forItemID: "rot"))
        #expect(image.width == 400 && image.height == 600)
    }

    @Test func undecodableBytesAreNotStored() throws {
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = GooglePhotosCache(directory: dir)
        #expect(try !cache.store(Data("<html>not an image</html>".utf8), forItemID: "x"))
        #expect(!cache.contains(itemID: "x"))
    }

    @Test func otherSourceRefsAreNotServed() throws {
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = GooglePhotosCache(directory: dir)
        try cache.store(G.png(width: 100, height: 100), forItemID: "a")
        #expect(cache.image(forSourceRef: "gphotos:a") != nil)
        #expect(cache.image(forSourceRef: "a") == nil)
        #expect(cache.image(forSourceRef: "gphotos:") == nil)
        #expect(cache.image(forSourceRef: "gphotos:missing") == nil)
    }

    @Test func pruneKeepsOnlyReferencedItemsAndRemoveAllDeletesEverything() throws {
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = GooglePhotosCache(directory: dir)
        for id in ["a", "b", "c"] { try cache.store(G.png(width: 64, height: 64), forItemID: id) }
        try cache.prune(keepingItemIDs: ["b", "zzz"])
        #expect(!cache.contains(itemID: "a") && cache.contains(itemID: "b") && !cache.contains(itemID: "c"))
        try cache.remove(itemID: "b")
        try cache.remove(itemID: "b")  // removing a missing item is fine
        try cache.store(G.png(width: 64, height: 64), forItemID: "d")
        try cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
        try cache.removeAll()
        #expect(try cache.cachedFiles().isEmpty)
    }
}
