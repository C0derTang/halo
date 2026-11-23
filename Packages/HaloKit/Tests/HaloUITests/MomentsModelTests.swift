import Foundation
import HaloCore
import Testing

@testable import HaloUI

private actor MomentsFakeStore: MemoryStoring {
    var hooks: [MemoryHook] = []
    var failFor: Set<PersonID> = []
    func setFail(_ ids: Set<PersonID>) { failFor = ids }
    func hooks(for person: PersonID, now: Date) async throws -> [MemoryHook] {
        hooks.filter { $0.personID == person }
    }
    func addHook(_ hook: MemoryHook) async throws {
        struct Boom: Error {}
        if failFor.contains(hook.personID) { throw Boom() }
        hooks.append(hook)
    }
    func replaceHooks(for person: PersonID, source: MemoryHook.Source, with hooks: [MemoryHook])
        async throws
    {}
    func deleteHook(id: UUID) async throws {}
}

private struct FakeSpeech: SpeechTranscribing {
    var available: Bool
    var parts: [String] = []
    var isOnDeviceAvailable: Bool { get async { available } }
    func transcribe() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            for p in parts { c.yield(p) }
            c.finish()
        }
    }
}

private final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var terminated: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Never-ending stream whose termination (mic release) is observable.
private struct HangingSpeech: SpeechTranscribing {
    let flag: TerminationFlag
    var isOnDeviceAvailable: Bool { get async { true } }
    func transcribe() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            c.onTermination = { _ in flag.set() }
            c.yield("hi")
        }
    }
}

private let alice = MomentsPerson(id: PersonID(), displayName: "Alice", isConfirmed: true)
private let bob = MomentsPerson(id: PersonID(), displayName: "Bob", isConfirmed: true)
private let stranger = MomentsPerson(id: PersonID(), displayName: "Maybe", isConfirmed: false)

@MainActor
private func make(
    _ people: [MomentsPerson], store: MomentsFakeStore = MomentsFakeStore(),
    speech: (any SpeechTranscribing)? = nil,
    sanitize: @escaping MomentsSanitizer = { $0 },
    verify: (@Sendable (PersonID) async -> Bool)? = nil
) -> MomentsModel {
    MomentsModel(
        people: people, store: store, speech: speech, sanitize: sanitize, verifyConfirmed: verify,
        now: { Date(timeIntervalSince1970: 1000) })
}

@MainActor
@Suite struct MomentsModelTests {
    @Test func savesOneHookPerSelectedPerson() async {
        let store = MomentsFakeStore()
        let model = make([alice, bob], store: store)
        model.toggle(alice.id)
        model.toggle(bob.id)
        model.setText("  Talked   about the trip ")
        #expect(await model.save())
        let hooks = await store.hooks
        #expect(hooks.count == 2)
        #expect(Set(hooks.map(\.personID)) == [alice.id, bob.id])
        #expect(hooks.allSatisfy { $0.source == .moment && $0.text == "Talked about the trip" })
        #expect(hooks.allSatisfy { $0.createdAt == Date(timeIntervalSince1970: 1000) })
    }

    @Test func onlySelectedAreTagged() async {
        let store = MomentsFakeStore()
        let model = make([alice, bob], store: store)
        model.toggle(bob.id)
        model.setText("Hi")
        _ = await model.save()
        #expect(await store.hooks.map(\.personID) == [bob.id])
    }

    @Test func unconfirmedAndUnknownCannotBeTagged() async {
        let store = MomentsFakeStore()
        let model = make([alice, stranger], store: store)
        #expect(model.people.map(\.id) == [alice.id])
        model.toggle(stranger.id)
        model.toggle(PersonID())  // unknown face / arbitrary id
        #expect(model.selected == [alice.id])  // only the preselected sole eligible person
        model.setText("Hello")
        _ = await model.save()
        #expect(await store.hooks.map(\.personID) == [alice.id])
    }

    @Test func nothingStoredWithoutRecognizedConfirmedPeople() async {
        let store = MomentsFakeStore()
        let model = make([stranger], store: store)
        model.setText("Hello")
        #expect(!model.canSave)
        #expect(await model.save() == false)
        #expect(await store.hooks.isEmpty)
    }

    @Test func forgottenPersonIsSkippedAtSaveTime() async {
        let store = MomentsFakeStore()
        let goneID = bob.id
        let model = make([alice, bob], store: store, verify: { $0 != goneID })
        model.toggle(alice.id)
        model.toggle(bob.id)
        model.setText("Hello")
        #expect(await model.save() == false)
        #expect(await store.hooks.map(\.personID) == [alice.id])
        #expect(model.errorMessage != nil)
    }

    @Test func sanitizationIsApplied() async {
        let store = MomentsFakeStore()
        let model = make([alice], store: store, sanitize: { $0.uppercased() })
        model.setText("quiet note")
        _ = await model.save()
        #expect(await store.hooks.first?.text == "QUIET NOTE")
    }

    @Test func rejectedBySanitizerStoresNothing() async {
        let store = MomentsFakeStore()
        let model = make([alice], store: store, sanitize: { _ in nil })
        model.setText("anything")
        #expect(await model.save() == false)
        #expect(await store.hooks.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(!model.didSave)
    }

    @Test func lengthIsLimitedTo140() async {
        let store = MomentsFakeStore()
        let model = make([alice], store: store)
        model.setText(String(repeating: "a", count: 300))
        #expect(model.text.count == 140)
        #expect(model.remaining == 0)
        _ = await model.save()
        #expect(await store.hooks.first?.text.count == 140)
    }

    @Test func emptyNoteCannotSave() async {
        let model = make([alice])
        model.setText("   ")
        #expect(!model.canSave)
        #expect(await model.save() == false)
    }

    @Test func storeFailureReported() async {
        let store = MomentsFakeStore()
        await store.setFail([bob.id])
        let model = make([alice, bob], store: store)
        model.toggle(alice.id)
        model.toggle(bob.id)
        model.setText("Hello")
        #expect(await model.save() == false)
        #expect(await store.hooks.count == 1)
    }

    @Test func dictationHiddenWhenOnDeviceUnavailable() async {
        let model = make([alice], speech: FakeSpeech(available: false, parts: ["x"]))
        await model.prepareDictation()
        #expect(!model.isDictationAvailable)
        model.startDictation()
        #expect(!model.isDictating)
        #expect(model.text.isEmpty)
    }

    @Test func dictationHiddenWithoutTranscriber() async {
        let model = make([alice])
        await model.prepareDictation()
        #expect(!model.isDictationAvailable)
    }

    @Test func dictationAppendsTranscriptAndClamps() async {
        let model = make(
            [alice], speech: FakeSpeech(available: true, parts: ["hello", "hello there"]))
        await model.prepareDictation()
        #expect(model.isDictationAvailable)
        model.setText("Met")
        model.startDictation()
        for _ in 0..<200 where model.isDictating { await Task.yield() }
        #expect(model.text == "Met hello there")
        #expect(!model.isDictating)
    }

    @Test func stopDictationTerminatesTheStream() async {
        let flag = TerminationFlag()
        let model = make([alice], speech: HangingSpeech(flag: flag))
        await model.prepareDictation()
        model.startDictation()
        for _ in 0..<200 where model.text.isEmpty { await Task.yield() }
        #expect(model.isDictating)
        model.stopDictation()
        #expect(!model.isDictating)
        for _ in 0..<2000 where !flag.terminated { await Task.yield() }
        #expect(flag.terminated)
    }

    @Test func savingStopsDictation() async {
        let flag = TerminationFlag()
        let model = make([alice], speech: HangingSpeech(flag: flag))
        await model.prepareDictation()
        model.startDictation()
        for _ in 0..<200 where model.text.isEmpty { await Task.yield() }
        _ = await model.save()
        for _ in 0..<2000 where !flag.terminated { await Task.yield() }
        #expect(flag.terminated)
    }

    @Test func retryDoesNotDuplicateAlreadyWrittenHooks() async {
        let store = MomentsFakeStore()
        await store.setFail([bob.id])
        let model = make([alice, bob], store: store)
        model.toggle(alice.id)
        model.toggle(bob.id)
        model.setText("Hello")
        #expect(await model.save() == false)
        await store.setFail([])
        #expect(await model.save())
        let hooks = await store.hooks
        #expect(hooks.count == 2)
        #expect(Set(hooks.map(\.personID)) == [alice.id, bob.id])
    }
}
