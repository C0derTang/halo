import HaloCore
import SwiftUI

/// Compact one-handed sheet: pick who, type or dictate up to 140 characters, save.
public struct MomentsSheet: View {
    @Bindable var model: MomentsModel
    let onDone: () -> Void

    public init(model: MomentsModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick note").font(.headline)
            if model.people.isEmpty {
                Text("No one recognized right now.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.people) { person in
                            let on = model.isSelected(person.id)
                            Button {
                                model.toggle(person.id)
                            } label: {
                                Text(person.displayName)
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .background(
                                        on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityHint("Double tap to \(on ? "deselect" : "select")")
                        }
                    }
                }
                HStack(alignment: .bottom) {
                    TextField(
                        "What happened?",
                        text: Binding(get: { model.text }, set: { model.setText($0) }), axis: .vertical
                    )
                    .lineLimit(1...3)
                    .accessibilityLabel("Note")
                    if model.isDictationAvailable {
                        Button {
                            model.toggleDictation()
                        } label: {
                            Image(systemName: model.isDictating ? "stop.circle.fill" : "mic.circle")
                                .font(.title).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(model.isDictating ? "Stop dictation" : "Dictate note")
                    }
                }
                HStack {
                    Text("\(model.remaining)")
                        .font(.caption).foregroundStyle(model.remaining < 20 ? .orange : .secondary)
                        .accessibilityLabel("\(model.remaining) characters left")
                    if let message = model.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        model.stopDictation()
                        onDone()
                    }
                    Button("Save") {
                        Task {
                            if await model.save() { onDone() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
                }
            }
        }
        .padding(16)
        .task { await model.prepareDictation() }
        .presentationDetents([.height(260), .medium])
    }
}
