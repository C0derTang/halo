import Foundation
import Testing

@testable import HaloCore

@Test func digestRoundTripsThroughJSON() throws {
    let digest = InteractionDigest(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        entries: [
            .init(
                handle: "+15555550100", lastMessageAt: nil, lastFromMeAt: nil, lastFromThemAt: nil,
                messagesLast30Days: 0, messagesAllTime: 0, awaitingMyReply: false)
        ])
    let data = try JSONEncoder().encode(digest)
    #expect(try JSONDecoder().decode(InteractionDigest.self, from: data) == digest)
}

@Test func nullMatcherRecognizesNoOne() {
    #expect(NullMatcher().match([1, 0, 0], policy: .conservative) == .unknown)
}
