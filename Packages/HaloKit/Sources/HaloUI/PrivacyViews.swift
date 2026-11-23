import HaloCore
import SwiftUI

struct PersonPrivacyRow: View {
    let item: PersonPrivacyItem
    let onForget: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.person.displayName).font(.body)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget", role: .destructive, action: onForget)
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let status = item.person.confirmed ? "Confirmed" : "Unconfirmed"
        let n = item.recognitionCount
        return "\(status) · recognized \(n) \(n == 1 ? "time" : "times")"
    }
}

public struct RecognitionLogView: View {
    let name: String
    let dates: [Date]

    public init(name: String, dates: [Date]) {
        self.name = name
        self.dates = dates
    }

    public var body: some View {
        List {
            if dates.isEmpty {
                Text("Never recognized")
            } else {
                ForEach(dates, id: \.self) { date in
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .navigationTitle(name)
    }
}

/// Settings root: privacy (people, recognition history, forget, erase everything). `sections` are
/// extra app sections (pairing, imports) shown above the privacy ones, inside the same
/// navigation stack.
public struct SettingsView<Sections: View>: View {
    let model: PrivacySettingsViewModel
    let sections: Sections
    @State private var showEraseSheet = false
    @State private var eraseText = ""

    public init(model: PrivacySettingsViewModel, @ViewBuilder sections: () -> Sections) {
        self.model = model
        self.sections = sections()
    }

    public var body: some View {
        NavigationStack {
            List {
                if model.hasPendingErasure {
                    Section {
                        Label(
                            "Erasure pending. It will finish when the app is backgrounded.",
                            systemImage: "hourglass")
                    }
                }
                sections
                Section("People") {
                    if model.items.isEmpty { Text("No people stored") }
                    ForEach(model.items) { item in
                        NavigationLink {
                            RecognitionLogDestination(model: model, person: item.person)
                        } label: {
                            PersonPrivacyRow(item: item) { model.requestForget(item.id) }
                        }
                    }
                }
                Section {
                    Button("Erase everything", role: .destructive) {
                        eraseText = ""
                        showEraseSheet = true
                    }
                } footer: {
                    Text("Deletes every person, face and record on this device. This cannot be undone.")
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Privacy")
            .task { await model.load() }
            .confirmationDialog(
                "Forget this person?",
                isPresented: Binding(
                    get: { model.pendingForget != nil },
                    set: { if !$0 { model.cancelForget() } }),
                titleVisibility: .visible,
                presenting: model.pendingForget
            ) { person in
                // `person` is captured at presentation, so the dismissal setter above cannot race it.
                Button("Forget permanently", role: .destructive) {
                    Task { await model.confirmForget(person) }
                }
                Button("Cancel", role: .cancel) { model.cancelForget() }
            } message: { _ in
                // No name here: presented UI is not under the privacy cover.
                Text("Deletes all face data and records for them. This cannot be undone.")
            }
            .sheet(isPresented: $showEraseSheet) { eraseSheet }
        }
    }

    private var eraseSheet: some View {
        NavigationStack {
            Form {
                Text("Type \(PrivacySettingsViewModel.eraseKeyword) to erase all data, then authenticate.")
                TextField(PrivacySettingsViewModel.eraseKeyword, text: $eraseText)
                    .autocorrectionDisabled()
                Button("Erase everything", role: .destructive) {
                    Task {
                        if await model.eraseEverything(typed: eraseText) { showEraseSheet = false }
                    }
                }
                .disabled(!model.canErase(typed: eraseText))
            }
            .navigationTitle("Erase everything")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showEraseSheet = false }
                }
            }
        }
    }
}

extension SettingsView where Sections == EmptyView {
    public init(model: PrivacySettingsViewModel) {
        self.init(model: model) { EmptyView() }
    }
}

private struct RecognitionLogDestination: View {
    let model: PrivacySettingsViewModel
    let person: Person
    @State private var dates: [Date] = []

    var body: some View {
        RecognitionLogView(name: person.displayName, dates: dates)
            .task { dates = await model.recognitionDates(for: person.id) }
    }
}
