import HaloCore
import SwiftUI

/// Full card for one recognized person: title, subtitle and every chip.
public struct ContextCard: View {
    public let data: LabelData

    public init(data: LabelData) {
        self.data = data
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        VStack(alignment: .leading, spacing: 10) {
            FringedText(text: data.title, font: .system(size: 24, weight: .semibold, design: .rounded))
            if let subtitle = data.subtitle {
                Text(subtitle)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(HoloPalette.cyan.opacity(0.85))
            }
            ForEach(Array(data.chips.enumerated()), id: \.offset) { _, chip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(for: chip.kind))
                        .foregroundStyle(HoloPalette.cyan)
                        .frame(width: 18)
                    Text(chip.text)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            shape
                .fill(HoloPalette.glass.opacity(0.6))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(HoloPalette.cyan.opacity(0.7), lineWidth: 1))
        )
        .shadow(color: HoloPalette.cyan.opacity(0.4), radius: 10)
    }

    static func symbol(for kind: LabelChip.Kind) -> String {
        switch kind {
        case .lastInteraction: "bubble.left"
        case .upcoming: "calendar"
        case .memoryHook: "sparkles"
        case .openLoop: "arrow.uturn.left"
        case .sharedPhoto: "photo"
        }
    }
}

enum PreviewData {
    static let label = LabelData(
        personID: PersonID(), title: "Sample Person", subtitle: "Preview roommate",
        chips: [
            LabelChip(kind: .lastInteraction, text: "Texted 2d ago", priority: 3),
            LabelChip(kind: .upcoming, text: "Birthday in 5d", priority: 2),
            LabelChip(kind: .openLoop, text: "Owes you a reply", priority: 1),
        ])
}

#Preview("ContextCard") {
    ContextCard(data: PreviewData.label)
        .padding()
        .background(.black)
}

#Preview("HologramLabel") {
    GeometryReader { geo in
        ZStack {
            Color.black
            HologramLabel(
                data: PreviewData.label, faceRect: CGRect(x: 120, y: 300, width: 110, height: 140),
                viewSize: geo.size, state: .stable)
            UnknownFaceRing(faceRect: CGRect(x: 40, y: 500, width: 90, height: 110))
        }
    }
}
