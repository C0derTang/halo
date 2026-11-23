import HaloCore
import SwiftUI

/// "Who is this?" card stack: one cluster at a time.
public struct EnrollmentTriageView: View {
    @State private var model: EnrollmentViewModel
    @State private var picking = false
    @State private var selectedForReject: Set<UUID> = []

    public init(model: EnrollmentViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 16) {
            header
            if let card = model.current {
                cardView(card)
            } else if model.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                emptyState
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .task { await model.load() }
        .onChange(of: model.current?.id) { selectedForReject = [] }
    }

    private var header: some View {
        HStack {
            Text("Who is this?").font(.title2.bold())
            Spacer()
            Text(model.progressText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(model.remaining) groups left to review")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle)
            Text(model.skippedCount > 0 ? "\(model.skippedCount) skipped" : "All caught up")
            if model.skippedCount > 0 {
                Button("Review skipped") { model.reviewSkipped() }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func cardView(_ card: EnrollmentCard) -> some View {
        VStack(spacing: 16) {
            FaceThumbnailView(face: card.representative)
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityLabel("Representative face of this group")

            if let suggested = card.suggestedPerson {
                Button {
                    Task { await model.acceptSuggestion(for: card) }
                } label: {
                    Label("Maybe \(suggested.displayName)? Tap to confirm", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Confirms this group as \(suggested.displayName)")
            }

            Text("Tap faces that are not the same person")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(card.members) { face in
                    let selected = selectedForReject.contains(face.id)
                    Button {
                        if selected {
                            selectedForReject.remove(face.id)
                        } else {
                            selectedForReject.insert(face.id)
                        }
                    } label: {
                        FaceThumbnailView(face: face)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 10).stroke(.red, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Face, marked not the same person" : "Face")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            if !selectedForReject.isEmpty {
                Button(role: .destructive) {
                    let ids = Array(selectedForReject)
                    Task { await model.reject(faces: ids, from: card) }
                } label: {
                    Text("Not the same person (\(selectedForReject.count))")
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)

            Button("This is…") { picking = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            HStack {
                Button("Skip") { model.skip(card) }
                Spacer()
                Button("Never suggest", role: .destructive) {
                    Task { await model.neverSuggest(card) }
                }
                .accessibilityHint("Deletes these faces")
            }
        }
        .sheet(isPresented: $picking) {
            PersonPickerView(model: model, card: card) { picking = false }
        }
    }
}

struct FaceThumbnailView: View {
    let face: EnrollmentFace

    var body: some View {
        if let image = face.image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "person.crop.square").foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
    #Preview("Triage") {
        EnrollmentTriageView(model: EnrollmentPreviewFakes.model())
    }
#endif
