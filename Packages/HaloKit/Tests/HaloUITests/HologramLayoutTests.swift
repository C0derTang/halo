import CoreGraphics
import HaloCore
import Testing

@testable import HaloUI

private let view = CGSize(width: 400, height: 800)

@Test func labelAnchoredAboveFace() {
    let face = CGRect(x: 150, y: 400, width: 100, height: 160)
    let p = HologramLayout.placement(faceRect: face, viewSize: view)
    #expect(p.frame.maxY < face.minY)
    #expect(abs(p.frame.midX - face.midX) < 0.001)
    #expect(p.anchor == CGPoint(x: face.midX, y: face.minY))
}

@Test func scaleClamps() {
    #expect(HologramLayout.scale(forFaceHeight: 1) == HologramLayout.minScale)
    #expect(HologramLayout.scale(forFaceHeight: 10_000) == HologramLayout.maxScale)
    #expect(HologramLayout.scale(forFaceHeight: 160) == 1)
    #expect(HologramLayout.scale(forFaceHeight: .nan) == HologramLayout.minScale)
    let big = HologramLayout.frame(
        faceRect: CGRect(x: 100, y: 500, width: 200, height: 1000), viewSize: view)
    #expect(big.width <= HologramLayout.baseSize.width * HologramLayout.maxScale + 0.001)
}

@Test func clampsAtAllFourEdges() {
    let inset = HologramLayout.edgeInset
    let bounds = CGRect(origin: .zero, size: view).insetBy(dx: inset, dy: inset)
    let faces = [
        CGRect(x: -50, y: 400, width: 100, height: 160),  // left
        CGRect(x: 350, y: 400, width: 100, height: 160),  // right
        CGRect(x: 150, y: 10, width: 100, height: 160),  // top
        CGRect(x: 150, y: 790, width: 100, height: 160),  // bottom
        CGRect(x: -50, y: -50, width: 100, height: 160),  // corner
    ]
    for face in faces {
        let f = HologramLayout.frame(faceRect: face, viewSize: view)
        #expect(bounds.contains(f), "frame \(f) escaped for face \(face)")
    }
}

@Test func tinyViewNeverOverflows() {
    let tiny = CGSize(width: 100, height: 40)
    let f = HologramLayout.frame(
        faceRect: CGRect(x: 10, y: 20, width: 50, height: 80), viewSize: tiny)
    #expect(CGRect(origin: .zero, size: tiny).contains(f))
}

@Test func chipsTruncatedToTwoInLabel() {
    let chips = (0..<5).map { LabelChip(kind: .memoryHook, text: "c\($0)", priority: Double(5 - $0)) }
    let data = LabelData(personID: PersonID(), title: "T", chips: chips)
    #expect(HologramLayout.visibleChips(data).map(\.text) == ["c0", "c1"])
    #expect(data.chips.count == 5)  // card keeps all
}

@Test func reduceMotionPathSelectable() {
    #expect(HologramMotion.resolve(reduceMotion: true) == .reduced)
    #expect(HologramMotion.resolve(reduceMotion: false) == .animated)
}
