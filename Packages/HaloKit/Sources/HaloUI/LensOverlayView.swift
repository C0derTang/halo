import HaloCore
import SwiftUI

/// The lens overlay: a hologram label over each recognized face, a faint text-free ring over
/// every other face, and a `ContextCard` sheet when a label is tapped.
///
/// Must be laid out with exactly the same bounds as the camera preview (e.g. as its `.overlay`),
/// because `LensOverlayGeometry` maps boxes into the preview's coordinate space.
///
/// Known-people-only (invariant 1): text is drawn only from `LensOverlayItem.label`, which the
/// screen model sets for confirmed, recognized people only. Items without a label get
/// `UnknownFaceRing`, which takes nothing but geometry. This view performs no lookups.
public struct LensOverlayView: View {
    public let items: [LensOverlayItem]
    public let frame: LensOverlayFrame?
    public let videoGravity: LensOverlayGeometry.VideoGravity

    @State private var selected: SelectedLabel?

    public init(
        items: [LensOverlayItem], frame: LensOverlayFrame?,
        videoGravity: LensOverlayGeometry.VideoGravity = .resizeAspectFill
    ) {
        self.items = items
        self.frame = frame
        self.videoGravity = videoGravity
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let frame {
                    ForEach(items) { item in
                        if let rect = LensOverlayGeometry.viewRect(
                            forUpright: item.rect, bufferSize: frame.bufferSize,
                            orientation: frame.orientation, viewSize: geo.size, videoGravity: videoGravity)
                        {
                            itemView(item, rect: rect, viewSize: geo.size)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .sheet(item: $selected) { selection in
            ContextCard(data: selection.data)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func itemView(_ item: LensOverlayItem, rect: CGRect, viewSize: CGSize) -> some View {
        if let label = item.label {
            HologramLabel(data: label, faceRect: rect, viewSize: viewSize, state: item.state)
            if item.state != .lost {
                // HologramLabel ignores hits; this transparent button over the card opens the sheet.
                let placement = HologramLayout.placement(faceRect: rect, viewSize: viewSize)
                Button {
                    selected = SelectedLabel(data: label)
                } label: {
                    Color.clear
                        .frame(width: placement.frame.width, height: placement.frame.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: placement.frame.midX, y: placement.frame.midY)
                .accessibilityLabel(Text(HologramLabel.accessibilityText(for: label)))
                .accessibilityHint(Text("Shows details"))
            }
        } else if item.state != .lost {
            UnknownFaceRing(faceRect: rect)
        }
    }
}

/// Sheet payload: a snapshot of the tapped label, so the card stays put if the track drops.
private struct SelectedLabel: Identifiable {
    let data: LabelData
    var id: PersonID { data.personID }
}

#if DEBUG
    #Preview("LensOverlayView") {
        let known = LabelData(
            personID: PersonID(), title: "Sample Person", subtitle: "Preview roommate",
            chips: [LabelChip(kind: .lastInteraction, text: "Texted 2d ago", priority: 1)])
        LensOverlayView(
            items: [
                LensOverlayItem(
                    trackID: TrackID(1), rect: CGRect(x: 0.3, y: 0.35, width: 0.3, height: 0.17),
                    state: .stable, label: known),
                LensOverlayItem(
                    trackID: TrackID(2), rect: CGRect(x: 0.1, y: 0.7, width: 0.22, height: 0.12),
                    state: .stable, label: nil),
            ],
            frame: LensOverlayFrame(bufferSize: CGSize(width: 1280, height: 720), orientation: .right)
        )
        .background(Color.black)
    }
#endif
