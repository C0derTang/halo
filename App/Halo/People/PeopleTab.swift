import HaloAppCore
import HaloCore
import HaloUI
import SwiftUI

/// People tab: confirmed people, person detail, and the "Who is this?" triage entry. Models come
/// from the environment, so they share its store, normalizer, ranker and forget path.
struct PeopleTab: View {
    let environment: AppEnvironment
    @State private var list: PeopleListModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _list = State(initialValue: environment.makePeopleListModel())
    }

    var body: some View {
        PeopleListView(model: list) { id in
            PersonDetailScreen(environment: environment, personID: id)
        } triage: {
            EnrollmentTriageView(model: environment.enrollment)
                .navigationTitle("Who is this?")
        }
        // Confirm, forget, edits, imports: reload the list.
        .onChange(of: environment.peopleRevision) {
            Task { await list.load() }
        }
    }
}

/// Owns one `PersonDetailModel` for the pushed person.
private struct PersonDetailScreen: View {
    let environment: AppEnvironment
    @State private var model: PersonDetailModel

    init(environment: AppEnvironment, personID: PersonID) {
        self.environment = environment
        _model = State(initialValue: environment.makePersonDetailModel(for: personID))
    }

    var body: some View {
        PersonDetailView(model: model)
            // Edits, imports and memory hook changes (refresh, Moments): rebuild the label preview.
            .onChange(of: environment.peopleRevision) {
                guard !model.didForget else { return }
                Task { await model.load() }
            }
    }
}
