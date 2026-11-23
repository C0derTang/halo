import SwiftUI

/// Faint neutral ring around an unrecognized face. Deliberately has no text and no identity
/// (known-people-only invariant): it takes nothing but geometry.
public struct UnknownFaceRing: View {
    public let faceRect: CGRect

    public init(faceRect: CGRect) {
        self.faceRect = faceRect
    }

    public var body: some View {
        Ellipse()
            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            .frame(width: faceRect.width, height: faceRect.height)
            .position(x: faceRect.midX, y: faceRect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
