import HaloCore
import SwiftUI

/// Floating holographic label. Renders only from the provided `LabelData`; performs no lookups.
public struct HologramLabel: View {
    public let data: LabelData
    public let faceRect: CGRect
    public let viewSize: CGSize
    public let state: HologramState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    public init(data: LabelData, faceRect: CGRect, viewSize: CGSize, state: HologramState) {
        self.data = data
        self.faceRect = faceRect
        self.viewSize = viewSize
        self.state = state
    }

    /// Title, subtitle and the chips actually shown on the label, comma separated.
    static func accessibilityText(for data: LabelData) -> String {
        var parts = [data.title]
        if let subtitle = data.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        parts += HologramLayout.visibleChips(data).map(\.text)
        return parts.joined(separator: ", ")
    }

    private var visible: Bool { shown && state != .lost }

    public var body: some View {
        let placement = HologramLayout.placement(faceRect: faceRect, viewSize: viewSize)
        let motion = HologramMotion.resolve(reduceMotion: reduceMotion)
        ZStack(alignment: .topLeading) {
            LeaderLine(
                from: CGPoint(x: placement.frame.midX, y: placement.frame.maxY), to: placement.anchor
            )
            .stroke(HoloPalette.cyan.opacity(0.7), lineWidth: 1)
            .shadow(color: HoloPalette.cyan, radius: 3)
            HologramCard(data: data, motion: motion, scale: placement.scale)
                .frame(width: placement.frame.width, height: placement.frame.height)
                .scaleEffect(visible ? 1 : 0.85)
                .position(x: placement.frame.midX, y: placement.frame.midY)
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.3), value: visible)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityText(for: data)))
        .onAppear { shown = true }
    }
}

struct LeaderLine: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

enum HoloPalette {
    static let cyan = Color(red: 0.25, green: 0.9, blue: 1.0)
    static let glass = Color(red: 0.05, green: 0.25, blue: 0.35)
}

struct HologramCard: View {
    let data: LabelData
    let motion: HologramMotion
    let scale: CGFloat

    var body: some View {
        switch motion {
        case .reduced:
            content(time: 0)
        case .animated:
            TimelineView(.animation) { ctx in
                content(time: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func content(time: Double) -> some View {
        let flicker = motion == .animated ? 0.92 + 0.08 * sin(time * 23) * sin(time * 7.3) : 1
        let shape = RoundedRectangle(cornerRadius: 12 * scale)
        return VStack(alignment: .leading, spacing: 3 * scale) {
            FringedText(
                text: data.title, font: .system(size: 17 * scale, weight: .semibold, design: .rounded))
            if let subtitle = data.subtitle {
                Text(subtitle)
                    .font(.system(size: 12 * scale, design: .rounded))
                    .foregroundStyle(HoloPalette.cyan.opacity(0.85))
                    .lineLimit(1)
            }
            HStack(spacing: 4 * scale) {
                ForEach(Array(HologramLayout.visibleChips(data).enumerated()), id: \.offset) { _, chip in
                    ChipView(text: chip.text, scale: scale)
                }
            }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            shape
                .fill(HoloPalette.glass.opacity(0.45))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(HoloPalette.cyan.opacity(0.8), lineWidth: 1))
                .overlay(Scanlines(time: time, animated: motion == .animated).clipShape(shape))
        }
        .shadow(color: HoloPalette.cyan.opacity(0.6), radius: 8 * scale)
        .opacity(flicker)
    }
}

struct Scanlines: View {
    let time: Double
    let animated: Bool

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3
            let offset = animated ? CGFloat((time * 12).truncatingRemainder(dividingBy: Double(spacing))) : 0
            var y = -spacing + offset
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(HoloPalette.cyan.opacity(0.10)))
                y += spacing
            }
            if animated {
                let band = CGFloat((time * 0.4).truncatingRemainder(dividingBy: 1)) * size.height
                context.fill(
                    Path(CGRect(x: 0, y: band, width: size.width, height: 6)),
                    with: .color(.white.opacity(0.08)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Text with offset red/blue copies blended with `.screen` for a chromatic fringe.
struct FringedText: View {
    let text: String
    let font: Font
    var lineLimit: Int = 1
    var minimumScaleFactor: CGFloat = 1

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(Color(red: 1, green: 0.2, blue: 0.4)).offset(x: -0.8)
                .blendMode(.screen)
            Text(text).foregroundStyle(Color(red: 0.2, green: 0.4, blue: 1)).offset(x: 0.8)
                .blendMode(.screen)
            Text(text).foregroundStyle(.white).blendMode(.screen)
        }
        .font(font)
        .lineLimit(lineLimit)
        .minimumScaleFactor(minimumScaleFactor)
        .shadow(color: HoloPalette.cyan, radius: 4)
    }
}

struct ChipView: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(HoloPalette.cyan)
            .lineLimit(1)
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 2 * scale)
            .background(Capsule().fill(HoloPalette.cyan.opacity(0.15)))
            .overlay(Capsule().strokeBorder(HoloPalette.cyan.opacity(0.5), lineWidth: 0.5))
    }
}
