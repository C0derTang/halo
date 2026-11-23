import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import Testing

@testable import HaloImport

#if canImport(Photos)
    import Photos
#endif

private typealias F = PhotoScanFixture

/// Date-descending with ties in reverse identifier order (as PhotoKit may return them).
private let tied: [PhotoAsset] = {
    let d0 = F.epoch
    let d1 = F.epoch.addingTimeInterval(-10)
    let d2 = F.epoch.addingTimeInterval(-20)
    return [
        PhotoAsset(localIdentifier: "a", creationDate: d0),
        PhotoAsset(localIdentifier: "e", creationDate: d1),
        PhotoAsset(localIdentifier: "d", creationDate: d1),
        PhotoAsset(localIdentifier: "c", creationDate: d1),
        PhotoAsset(localIdentifier: "b", creationDate: d1),
        PhotoAsset(localIdentifier: "f", creationDate: d2),
    ]
}()

private func pageAll(limit: Int) -> [PhotoAsset] {
    var all: [PhotoAsset] = []
    var position: PhotoAsset?
    while true {
        let page = PhotoScanPaging.page(count: tied.count, asset: { tied[$0] }, after: position, limit: limit)
        if page.isEmpty { return all }
        #expect(page.count <= limit)
        all += page
        position = page.last
    }
}

@Suite struct PhotoScanSourceTests {
    @Test(arguments: 1...7)
    func pagingVisitsEveryAssetOnceInScanOrder(limit: Int) {
        let expected = tied.sorted { $0.precedes($1) }
        #expect(expected.map(\.localIdentifier) == ["a", "b", "c", "d", "e", "f"])
        #expect(pageAll(limit: limit) == expected)
    }

    @Test func pagingResumesInsideATieGroup() {
        let cursor = PhotoAsset(localIdentifier: "c", creationDate: F.epoch.addingTimeInterval(-10))
        let page = PhotoScanPaging.page(count: tied.count, asset: { tied[$0] }, after: cursor, limit: 10)
        #expect(page.map(\.localIdentifier) == ["d", "e", "f"])
        #expect(PhotoScanPaging.page(count: tied.count, asset: { tied[$0] }, after: nil, limit: 0).isEmpty)
    }

    @Test func scanOrderIsNewestFirstThenIdentifier() {
        let newer = PhotoAsset(localIdentifier: "z", creationDate: F.epoch)
        let older = PhotoAsset(localIdentifier: "a", creationDate: F.epoch.addingTimeInterval(-1))
        #expect(newer.precedes(older))
        #expect(!older.precedes(newer))
        let tieA = PhotoAsset(localIdentifier: "a", creationDate: F.epoch)
        #expect(tieA.precedes(newer))
        #expect(!tieA.precedes(tieA))
    }

    @Test func inMemoryLibraryPagesAndRecordsLoads() async throws {
        let library = InMemoryPhotoLibrary([
            (F.asset(1), PhotoScanImage(image: F.image(width: 4, height: 2))),
            (F.asset(0), nil),
        ])
        let first = try await library.assets(after: nil, limit: 1)
        #expect(first == [F.asset(0)])
        #expect(try await library.assets(after: first[0], limit: 5) == [F.asset(1)])
        #expect(try await library.loadImage(for: F.asset(0), maxPixelSize: 1024) == nil)
        #expect(try await library.loadImage(for: F.asset(1), maxPixelSize: 1024)?.image.width == 4)
        #expect(await library.loadedIdentifiers == ["asset-0", "asset-1"])
    }

    @Test func cursorRoundTripsAndFallsBackToFresh() throws {
        let space = EmbeddingSpace(modelID: "m", dimension: 8)
        var cursor = PhotoScanCursor(space: space)
        cursor.completedTop = F.asset(0)
        cursor.passTop = F.asset(1)
        cursor.resumeAfter = F.asset(2)
        let encoded = try cursor.encoded()
        #expect(PhotoScanCursor.decode(encoded, space: space) == cursor)
        #expect(PhotoScanCursor.decode(nil, space: space) == PhotoScanCursor(space: space))
        #expect(PhotoScanCursor.decode("not json", space: space) == PhotoScanCursor(space: space))
        let other = EmbeddingSpace(modelID: "other", dimension: 8)
        #expect(PhotoScanCursor.decode(encoded, space: other) == PhotoScanCursor(space: other))
    }

    @Test func requestTargetFitsTheLongEdgeAndNeverUpscales() {
        #expect(
            PhotoScanImageSizing.targetSize(pixelWidth: 4032, pixelHeight: 3024, maxPixelSize: 1024)
                == CGSize(width: 1024, height: 768))
        #expect(
            PhotoScanImageSizing.targetSize(pixelWidth: 3024, pixelHeight: 4032, maxPixelSize: 1024)
                == CGSize(width: 768, height: 1024))
        #expect(
            PhotoScanImageSizing.targetSize(pixelWidth: 640, pixelHeight: 480, maxPixelSize: 1024)
                == CGSize(width: 640, height: 480))
        #expect(
            PhotoScanImageSizing.targetSize(pixelWidth: 0, pixelHeight: 0, maxPixelSize: 1024)
                == CGSize(width: 1024, height: 1024))
    }

    #if canImport(Photos)
        /// Builds request options only; never touches the Photos library.
        @Test func photoKitRequestsAreLocalOnlyBestQuality() {
            let options = PhotoKitLibrarySource.requestOptions()
            #expect(options.isNetworkAccessAllowed == false)
            #expect(options.deliveryMode == .highQualityFormat)
            #expect(options.isSynchronous == false)
            #expect(options.version == .current)
        }
    #endif
}
