import CoreGraphics
import Foundation
import HaloCore
import HaloLens
import HaloUI
import Testing

@testable import HaloAppCore

@MainActor
struct LensScreenModelTests {
    let source = LensFakeTrackSource()
    let camera = LensFakeCamera()
    let store = LensFakeStore()

    init() {
        store.add(Person(id: lensPersonID(1), displayName: "Ada Example", confirmed: true))
        store.add(
            Person(id: lensPersonID(2), displayName: "Ben Example", confirmed: true),
            identities: [Identity(personID: lensPersonID(2), kind: .phone, value: "+15550000002")])
    }

    func makeModel(recognitionAvailable: Bool = true) -> LensScreenModel {
        LensScreenModel(
            source: source, camera: camera, store: store, ranker: LensDigestEchoRanker(),
            recognitionAvailable: recognitionAvailable, now: { Date(timeIntervalSince1970: 42) })
    }

    // MARK: Known people only (invariant 1)

    @Test func onlyKnownTracksGetLabelData() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1)), lensTrack(2, .unknown), lensTrack(3, .ambiguous)])
        await model.settle()

        #expect(model.items.map(\.trackID) == [TrackID(1), TrackID(2), TrackID(3)])
        #expect(model.items[0].label?.title == "Ada Example")
        #expect(model.items[0].label?.personID == lensPersonID(1))
        #expect(model.items[1].label == nil)
        #expect(model.items[2].label == nil)
    }

    @Test func unknownAndAmbiguousFacesAreNeverLookedUpOrLogged() async {
        let model = makeModel()
        await model.start()
        for _ in 0..<5 {
            model.apply([lensTrack(1, .unknown), lensTrack(2, .ambiguous, x: 0.6)])
        }
        await model.settle()

        #expect(store.personLookups.isEmpty)
        #expect(store.identityLookups.isEmpty)
        #expect(store.logged.isEmpty)
        #expect(model.items.allSatisfy { $0.label == nil })
    }

    @Test func knownTrackShowsRingUntilItsLabelLoads() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        // Synchronously after the frame: no label yet (renders as a ring, no text).
        #expect(model.items.first?.label == nil)
        await model.settle()
        #expect(model.items.first?.label?.title == "Ada Example")
    }

    @Test func unconfirmedOrMissingPersonGetsNoLabel() async {
        store.add(Person(id: lensPersonID(3), displayName: "Unconfirmed Example", confirmed: false))
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(3)), lensTrack(2, lensKnown(99), x: 0.6)])
        await model.settle()

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.label == nil })
        // Not retried on every frame.
        model.apply([lensTrack(1, lensKnown(3)), lensTrack(2, lensKnown(99), x: 0.6)])
        await model.settle()
        #expect(store.personLookups.count == 2)
    }

    @Test func storeFailureGetsNoLabel() async {
        store.setFailLookups(true)
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.first?.label == nil)
    }

    @Test func labelFollowsTheTrackWhenIdentityChanges() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.first?.label != nil)
        // Pipeline drops the identity (e.g. re-verification failed or setMatcher after forget).
        model.apply([lensTrack(1, .unknown)])
        #expect(model.items.first?.label == nil)
    }

    // MARK: Recognition log

    @Test func recognitionIsLoggedOncePerPersonPerSession() async {
        let model = makeModel()
        await model.start()
        for _ in 0..<10 {
            model.apply([lensTrack(1, lensKnown(1)), lensTrack(2, lensKnown(2), x: 0.6)])
        }
        // Same person on a new track (left and came back) in the same session: still once.
        model.apply([lensTrack(7, lensKnown(1))])
        await model.settle()
        #expect(store.logged.count == 2)
        #expect(Set(store.logged) == [lensPersonID(1), lensPersonID(2)])
        #expect(store.loggedDates.allSatisfy { $0 == Date(timeIntervalSince1970: 42) })

        // A new session logs again.
        model.stop()
        await model.start()
        model.apply([lensTrack(9, lensKnown(1))])
        model.apply([lensTrack(9, lensKnown(1))])
        await model.settle()
        #expect(store.logged.filter { $0 == lensPersonID(1) }.count == 2)
        #expect(store.logged.count == 3)
    }

    @Test func nothingIsLoggedOrShownWhileStopped() async {
        let model = makeModel()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.isEmpty)
        #expect(store.logged.isEmpty)
        #expect(store.personLookups.isEmpty)
    }

    // MARK: Label cache

    @Test func labelIsCachedPerPerson() async {
        let model = makeModel()
        await model.start()
        for _ in 0..<5 { model.apply([lensTrack(1, lensKnown(2))]) }
        await model.settle()
        // Track lost and the person reappears on a new track: still cached.
        model.apply([])
        model.apply([lensTrack(5, lensKnown(2))])
        await model.settle()
        #expect(store.personLookups == [lensPersonID(2)])
        #expect(model.items.first?.label?.subtitle == "digest:-1 ids:1")
    }

    @Test func refreshLabelsPicksUpANewDigest() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.first?.label?.subtitle == "digest:-1 ids:0")

        store.setDigest(lensDigest(entries: 3))
        model.refreshLabels()
        // The old label stays up while the new one loads (no flicker to a ring).
        #expect(model.items.first?.label?.subtitle == "digest:-1 ids:0")
        await model.settle()
        #expect(model.items.first?.label?.subtitle == "digest:3 ids:0")
        #expect(store.personLookups == [lensPersonID(1), lensPersonID(1)])
    }

    @Test func refreshLabelsDropsAForgottenPerson() async throws {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.first?.label != nil)

        try await store.forget(lensPersonID(1))
        model.refreshLabels()
        await model.settle()
        #expect(model.items.first?.label == nil)
    }

    @Test func refreshDiscardsLoadsStartedBeforeIt() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])  // load #1 in flight with no digest
        store.setDigest(lensDigest(entries: 2))
        model.refreshLabels()  // load #2 supersedes it
        await model.settle()
        #expect(model.items.first?.label?.subtitle == "digest:2 ids:0")
    }

    @Test func newSessionRebuildsLabels() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        model.stop()
        store.setDigest(lensDigest(entries: 4))
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        await model.settle()
        #expect(model.items.first?.label?.subtitle == "digest:4 ids:0")
    }

    // MARK: Session, camera and frames

    @Test func startInstallsFrameHandlerThatFeedsThePipelineOffMain() async throws {
        let model = makeModel()
        await model.start()
        #expect(camera.starts == 1)
        #expect(camera.hasHandler)
        #expect(model.isRunning)
        #expect(model.isCapturing)

        let frame = lensBlankFrame(width: 1280, height: 720, orientation: .right)
        await Task.detached { [camera] in
            camera.deliver(frame)
            camera.deliver(frame)
        }.value
        #expect(source.submittedCount == 2)
        // Frame geometry reaches the main actor once.
        for _ in 0..<100 where model.frame == nil { await Task.yield() }
        #expect(
            model.frame == LensOverlayFrame(bufferSize: CGSize(width: 1280, height: 720), orientation: .right)
        )
    }

    @Test func stopTurnsTheCameraOffAndClearsTheOverlay() async {
        let model = makeModel()
        await model.start()
        model.apply([lensTrack(1, lensKnown(1))])
        model.stop()
        #expect(!model.isRunning)
        #expect(!model.isCapturing)
        #expect(camera.stops == 1)
        #expect(!camera.hasHandler)
        #expect(model.items.isEmpty)
    }

    @Test func cameraFailureIsReportedAndNothingRuns() async {
        camera.startError = CameraFailure()
        let model = makeModel()
        await model.start()
        #expect(!model.isRunning)
        #expect(!model.isCapturing)
        #expect(model.cameraError != nil)
        #expect(!camera.hasHandler)
    }

    @Test func recognitionUnavailableRunsPreviewWithoutFeedingFrames() async {
        let model = makeModel(recognitionAvailable: false)
        await model.start()
        #expect(model.isRunning)
        #expect(camera.starts == 1)
        #expect(!camera.hasHandler)
        #expect(!model.recognitionAvailable)
    }

    @Test func pipelineStreamDrivesTheOverlay() async {
        let model = makeModel()
        await model.start()
        source.continuation.yield([lensTrack(4, lensKnown(1)), lensTrack(5, .unknown, x: 0.6)])
        for _ in 0..<200 where model.items.first?.label == nil {
            await Task.yield()
            await model.settle()
        }
        #expect(model.items.map(\.trackID) == [TrackID(4), TrackID(5)])
        #expect(model.items[0].label?.title == "Ada Example")
        #expect(model.items[1].label == nil)
        #expect(model.items[0].rect == CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.15))
    }

    @Test func trackStateMapsToHologramState() async {
        let model = makeModel()
        await model.start()
        model.apply([
            lensTrack(1, .unknown, state: .appearing), lensTrack(2, .unknown, state: .stable),
            lensTrack(3, .unknown, state: .lost),
        ])
        #expect(model.items.map(\.state) == [.appearing, .stable, .lost])
    }
}

private struct CameraFailure: Error {}
