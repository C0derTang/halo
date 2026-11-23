import HaloCore
import SwiftUI

/// Pick an existing person (searchable) or create a new one by name for a cluster.
/// Nothing is confirmed until the user taps a row or "Create".
public struct PersonPickerView: View {
    let model: EnrollmentViewModel
    let card: EnrollmentCard
    let onDone: () -> Void

    @State private var query = ""
    @State private var results: [Person] = []

    public init(model: EnrollmentViewModel, card: EnrollmentCard, onDone: @escaping () -> Void) {
        self.model = model
        self.card = card
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Button {
                        Task {
                            if await model.confirmNewPerson(named: name, for: card) { onDone() }
                        }
                    } label: {
                        Label("Create \"\(name)\"", systemImage: "person.badge.plus")
                    }
                }
                Section("People") {
                    ForEach(results) { person in
                        Button(person.displayName) {
                            Task { if await model.confirm(card, as: person) { onDone() } }
                        }
                        .accessibilityHint("Confirms this group as \(person.displayName)")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search or enter a name")
            .navigationTitle("This is…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
            }
            .task(id: query) { results = await model.searchPeople(query) }
        }
    }
}
