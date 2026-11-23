import Foundation
import HaloCore
import HaloLens
import HaloMatching

/// Something that recognizes faces against a gallery and must be told when it changes.
public protocol GalleryMatcherSink: AnyObject, Sendable {
    func setMatcher(_ matcher: any FaceMatching) async
}

extension LensPipeline: GalleryMatcherSink {}

/// Rebuilds the `GalleryMatcher` from `confirmedGallery(space:)` and hands it to the lens.
///
/// - Runs on its own actor: the store read and the matcher build never touch the main actor.
/// - `requestRefresh()` is debounced, so a burst of changes (a contacts import, a triage session)
///   costs one rebuild.
/// - A person being forgotten is `exclude`d immediately, before the store deletes them: the lens
///   stops recognizing them at once, and a rebuild whose store read started before the forget can
///   never bring them back (every build filters excluded people).
/// - Matchers reach the sink in the order they were built (a serial apply chain), so an older
///   gallery never overwrites a newer one.
actor GalleryRefresher {
    private let store: any PeopleStoring
    private let space: EmbeddingSpace
    private let sink: any GalleryMatcherSink
    private let debounce: Duration
    private let onApply: @Sendable (GalleryMatcher) async -> Void

    private var gallery: [FaceEmbedding] = []
    private var excluded: Set<PersonID> = []
    /// Bumped by every request; a store read only applies if no newer request arrived meanwhile.
    private var generation = 0
    private var pending: Task<Void, Never>?
    private var applyChain: Task<Void, Never>?

    init(
        store: any PeopleStoring, space: EmbeddingSpace, sink: any GalleryMatcherSink, debounce: Duration,
        onApply: @escaping @Sendable (GalleryMatcher) async -> Void
    ) {
        self.store = store
        self.space = space
        self.sink = sink
        self.debounce = debounce
        self.onApply = onApply
    }

    /// Debounced rebuild from the store.
    func requestRefresh() {
        generation += 1
        let wanted = generation
        pending?.cancel()
        let debounce = self.debounce
        pending = Task {
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            await self.rebuild(generation: wanted)
        }
    }

    /// Immediate rebuild from the store (startup). Waits until the matcher reached the sink.
    func refreshNow() async {
        generation += 1
        pending?.cancel()
        await rebuild(generation: generation)
    }

    /// Waits for any scheduled rebuild and the apply chain (tests, shutdown).
    func settle() async {
        while let task = pending {
            await task.value
            if pending == task { pending = nil }
        }
        await applyChain?.value
    }

    /// Drops `id` from the lens right now, ahead of the store deletion.
    func exclude(_ id: PersonID) async {
        excluded.insert(id)
        generation += 1  // a read in flight may predate the forget
        await apply()
    }

    /// The forget failed: `id` still exists and may be recognized again after the next rebuild.
    func include(_ id: PersonID) {
        excluded.remove(id)
    }

    /// Kill switch: forget the cached gallery and recognize no one until the next rebuild.
    func reset() async {
        pending?.cancel()
        pending = nil
        generation += 1
        gallery = []
        excluded = []
        await apply()
    }

    private func rebuild(generation wanted: Int) async {
        guard let fresh = try? await store.confirmedGallery(space: space) else { return }
        guard wanted == generation else { return }  // superseded by a newer request
        gallery = fresh
        await apply()
    }

    private func apply() async {
        let excluded = self.excluded
        let matcher = GalleryMatcher(
            gallery: gallery.filter { embedding in
                guard let id = embedding.personID else { return false }
                return !excluded.contains(id)
            },
            space: space)
        let previous = applyChain
        let sink = self.sink
        let onApply = self.onApply
        let task = Task {
            await previous?.value
            await sink.setMatcher(matcher)
            await onApply(matcher)
        }
        applyChain = task
        await task.value
    }
}
