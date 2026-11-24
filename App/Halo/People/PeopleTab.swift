import HaloAppCore
import HaloCore
import HaloUI
import SwiftUI

/// People tab: confirmed people, person detail, the "Who is this?" triage entry and "Add from
/// Google Photos" (when this build has a Google client ID). Models come from the environment, so
/// they share its store, normalizer, ranker and forget path.
struct PeopleTab: View {
    let environment: AppEnvironment
    @State private var list: PeopleListModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _list = State(initialValue: environment.makePeopleListModel())
    }

    /// Screens pushed on top of the list (the Google Photos bar shows on the list only).
    @State private var pushed = 0

    var body: some View {
        PeopleListView(model: list) { id in
            PersonDetailScreen(environment: environment, personID: id)
                .onAppear { pushed += 1 }
                .onDisappear { pushed -= 1 }
        } triage: {
            EnrollmentTriageView(model: environment.enrollment)
                .navigationTitle("Who is this?")
                .onAppear { pushed += 1 }
                .onDisappear { pushed -= 1 }
        }
        // Next to the Photos scan: pick photos in Google Photos. Imported faces land in
        // "Who is this?" as suggestions (the import bumps `peopleRevision`).
        .safeAreaInset(edge: .bottom) {
            if environment.googleImport.isConfigured, pushed <= 0 {
                VStack(alignment: .leading, spacing: 4) {
                    GooglePhotosImportControls(model: environment.googleImport)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
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
