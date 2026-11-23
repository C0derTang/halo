import HaloCore
import SwiftUI

/// People tab root. `triage` builds the enrollment screen the "Needs review" row links to.
public struct PeopleListView<Detail: View, Triage: View>: View {
    @Bindable var model: PeopleListModel
    let detail: (PersonID) -> Detail
    let triage: () -> Triage

    public init(
        model: PeopleListModel, @ViewBuilder detail: @escaping (PersonID) -> Detail,
        @ViewBuilder triage: @escaping () -> Triage
    ) {
        self.model = model
        self.detail = detail
        self.triage = triage
    }

    public var body: some View {
        NavigationStack {
            List {
                if model.needsReviewCount > 0 {
                    Section("Needs review") {
                        NavigationLink {
                            triage()
                        } label: {
                            HStack {
                                Text("Who is this?")
                                Spacer()
                                Text("\(model.needsReviewCount)").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Needs review, \(model.needsReviewCount) waiting")
                    }
                }
                Section("People") {
                    ForEach(model.rows) { row in
                        NavigationLink {
                            detail(row.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.person.displayName)
                                if let rel = row.person.relationship {
                                    Text(rel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("People")
            .searchable(text: $model.searchText, prompt: "Search by name")
            .toolbar {
                Picker("Sort", selection: $model.sort) {
                    Text("Recent").tag(PeopleListModel.Sort.lastInteraction)
                    Text("Name").tag(PeopleListModel.Sort.name)
                }
                .pickerStyle(.menu)
            }
            .task { await model.load() }
        }
    }
}

public struct PersonDetailView: View {
    @Bindable var model: PersonDetailModel
    @State private var name = ""
    @State private var relationship = ""
    @State private var confirmingForget = false
    @Environment(\.dismiss) private var dismiss

    public init(model: PersonDetailModel) { self.model = model }

    public var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                TextField("Relationship", text: $relationship)
                Button("Save") { Task { await model.save(name: name, relationship: relationship) } }
            }
            if let label = model.labelPreview {
                Section("Lens label preview") {
                    Text(label.title).font(.headline)
                    if let sub = label.subtitle { Text(sub).foregroundStyle(.secondary) }
                    ForEach(label.chips, id: \.self) { Text($0.text) }
                }
            }
            if !model.identities.isEmpty {
                Section("Identities") {
                    ForEach(model.identities, id: \.self) {
                        LabeledContent($0.kind.rawValue, value: $0.value)
                    }
                }
            }
            Section("Faces (\(model.faceCount))") {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.faces) { face in
                            Group {
                                if let image = face.image {
                                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.3)
                                }
                            }
                            .frame(width: 56, height: 56).clipShape(.circle)
                            .accessibilityLabel("Face thumbnail")
                        }
                    }
                }
            }
            Section("Recognition history") {
                if model.recognitions.isEmpty {
                    Text("Not recognized yet").foregroundStyle(.secondary)
                }
                ForEach(model.recognitions, id: \.self) {
                    Text($0.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                Button("Forget this person", role: .destructive) { confirmingForget = true }
                    .disabled(model.isForgetting)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(model.person?.displayName ?? "Person")
        .task {
            await model.load()
            name = model.person?.displayName ?? ""
            relationship = model.person?.relationship ?? ""
        }
        .confirmationDialog(
            "Forget this person?",
            isPresented: $confirmingForget, titleVisibility: .visible,
            presenting: model.person
        ) { person in
            // `person` is captured at presentation; the dialog's dismissal cannot race the action.
            Button("Forget permanently", role: .destructive) {
                Task { if await model.confirmForget(person) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // No name here: presented UI is not under the privacy cover.
            Text("Deletes all face data and records for them. This cannot be undone.")
        }
    }
}
