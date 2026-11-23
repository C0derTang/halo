import Foundation
import Observation

/// Screen model around `DigestImporter`. The root view calls `importDigest(url:)` from `onOpenURL`
/// or a document picker (wave-4 wires the hookup).
@Observable @MainActor
public final class DigestImportModel {
    public enum Status: Equatable, Sendable {
        case idle
        case importing
        case succeeded(DigestImportReport)
        case failed(DigestImportError)
    }

    public private(set) var status: Status = .idle
    @ObservationIgnored private let importer: DigestImporter

    public init(importer: DigestImporter) { self.importer = importer }

    /// Text for the UI, nil when there is nothing to show.
    public var message: String? {
        switch status {
        case .idle, .importing: return nil
        case .succeeded(let r):
            return "Imported \(r.entryCount) conversations; \(r.resolvedPeople) matched people you know."
        case .failed(let e): return e.userMessage
        }
    }

    public func importDigest(url: URL) async {
        status = .importing
        do {
            status = .succeeded(try await importer.importDigest(url: url))
        } catch let error as DigestImportError {
            status = .failed(error)
        } catch {
            status = .failed(.unreadable)
        }
    }
}
