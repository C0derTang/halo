import CoreGraphics
import Foundation
import HaloCore
import Synchronization

@testable import HaloAppCore

// Synthetic Google Photos importer for the app wiring tests. No network, no Google ids or URLs:
// media items are "gphotos:synthetic-N" refs and the "photos" are solid generated images.

/// Lets the harness hand the fake the services the app builds the importer from.
protocol EnvGooglePhotosAttaching: Sendable {
    func attach(_ services: GooglePhotosServices)
}

final class EnvFakeGooglePhotos: GooglePhotosImporting, EnvGooglePhotosAttaching {
    enum Mode: Sendable {
        /// Reports `.waitingForPicker` and parks until cancelled. Once cancelled it still tries
        /// one write (after a short, non-cancellable delay), like a download that finished late.
        case blockUntilCancelled
        /// Keeps writing one face at a time, IGNORING cancellation, until `eraseAll()` runs (the
        /// real importer's eraseAll stops its own work), then throws `CancellationError`.
        case writeLoop
        /// Waits on `gate` (in the picker), then reports `.scanning` and writes one face every few
        /// milliseconds until cancelled (cooperatively, like the real importer).
        case scanUntilCancelled(gate: EnvGate?)
        /// Waits on `gate`, then imports `faces` unconfirmed faces and one cluster suggestion.
        case succeed(faces: Int, gate: EnvGate?)
        case fail(GooglePhotosImportError)
    }

    let log: EnvEventLog
    let configured: Bool
    let mode: Mode

    private struct State {
        var services: GooglePhotosServices?
        var signedIn = true
        var erased = false
        var cache: [String: CGImage] = [:]
    }
    private let state = Mutex(State())

    init(log: EnvEventLog, configured: Bool = true, mode: Mode, signedIn: Bool = true) {
        self.log = log
        self.configured = configured
        self.mode = mode
        state.withLock { $0.signedIn = signedIn }
    }

    func attach(_ services: GooglePhotosServices) { state.withLock { $0.services = services } }
    var services: GooglePhotosServices? { state.withLock { $0.services } }
    var isErased: Bool { state.withLock { $0.erased } }
    func setCached(_ image: CGImage, for ref: String) { state.withLock { $0.cache[ref] = image } }

    var isConfigured: Bool { configured }
    func isSignedIn() async -> Bool { state.withLock { $0.signedIn } }

    func importPicked(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void) async throws
        -> GooglePhotosImportProgress
    {
        log.record("google.import")
        guard let services else { throw GooglePhotosImportError.notConfigured }
        state.withLock { $0.erased = false }
        progress(GooglePhotosImportProgress(phase: .signingIn))
        progress(GooglePhotosImportProgress(phase: .waitingForPicker))
        switch mode {
        case .blockUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                log.record("google.cancelled")
                await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
                await write(
                    Self.face(1, space: services.embedder.space), to: services.store, tag: "lateWrite")
                log.record("google.returned")
                throw CancellationError()
            }
            return GooglePhotosImportProgress(phase: .finished)
        case .writeLoop:
            progress(GooglePhotosImportProgress(phase: .scanning, picked: 100))
            var n = 0
            while !isErased, n < 2000 {
                n += 1
                await write(Self.face(n, space: services.embedder.space), to: services.store, tag: "write")
                await Task.detached { try? await Task.sleep(for: .milliseconds(2)) }.value
            }
            log.record("google.returned")
            throw CancellationError()
        case .scanUntilCancelled(let gate):
            await gate?.wait()
            progress(GooglePhotosImportProgress(phase: .scanning, picked: 100))
            var n = 0
            do {
                while true {
                    n += 1
                    await write(
                        Self.face(n, space: services.embedder.space), to: services.store, tag: "write")
                    try await Task.sleep(for: .milliseconds(3))
                }
            } catch {
                log.record("google.returned")
                throw CancellationError()
            }
        case .succeed(let faces, let gate):
            await gate?.wait()
            progress(GooglePhotosImportProgress(phase: .downloading, picked: faces, downloaded: faces))
            let space = services.embedder.space
            let embeddings = (0..<faces).map { Self.face($0, space: space) }
            try await services.store.addEmbeddings(embeddings)
            if let first = embeddings.first {
                try await services.store.replaceClusters([
                    ClusterRecord(
                        id: "synthetic-google-cluster", memberIDs: embeddings.map(\.id),
                        representativeID: first.id, cohesion: 0.9)
                ])
            }
            log.record("google.imported")
            return GooglePhotosImportProgress(
                phase: .finished, picked: faces, downloaded: faces, facesEmbedded: faces)
        case .fail(let error):
            throw error
        }
    }

    private func write(_ face: FaceEmbedding, to store: any PeopleStoring & EnrollmentStoring, tag: String)
        async
    {
        do {
            try await store.addEmbeddings([face])
            log.record("google.\(tag)")
        } catch {
            log.record("google.\(tag).refused")
        }
    }

    func cachedImage(for sourceRef: String) async -> CGImage? { state.withLock { $0.cache[sourceRef] } }

    func signOut() async {
        log.record("google.signOut")
        state.withLock { $0.signedIn = false }
    }

    func eraseAll() async throws {
        log.record("google.eraseAll")
        state.withLock {
            $0.erased = true
            $0.signedIn = false
            $0.cache = [:]
        }
    }

    /// A synthetic unconfirmed face from a picked Google photo (unit vector, no real biometrics).
    static func face(_ n: Int, space: EmbeddingSpace) -> FaceEmbedding {
        FaceEmbedding(
            space: space, vector: [0, 0, 0, 1], source: .googlePhotos, sourceRef: "gphotos:synthetic-\(n)",
            quality: 0.9, faceBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25))
    }
}
