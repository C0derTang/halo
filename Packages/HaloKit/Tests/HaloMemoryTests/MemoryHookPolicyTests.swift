import Foundation
import HaloCore
import Testing

@testable import HaloMemory

@Suite struct MemoryHookPolicyTests {
    @Test(arguments: [
        "Recovering from surgery", "Was hospitalized last week", "Has a doctor's appointment",
        "Feeling depressed lately", "Pregnant with twins", "Going to therapy", "Got sick again",
        "Started going to church", "Fasting for Ramadan", "Praying for a new job", "Converted to Islam",
        "Just came out as gay", "Bisexual and proud", "On Tinder again", "Back on Grindr",
        "Paid off the mortgage", "Owes me 50 bucks", "Got a $5k raise", "Salary bump at Acme",
        "Struggling with debt", "Got laid off", "Into crypto now", "Rent went up",
    ])
    func sensitiveTopicsAreRejected(text: String) {
        #expect(SensitiveTopicFilter.isSensitive(text))
        #expect(MemoryHookPolicy.sanitize([text]).isEmpty)
    }

    @Test(arguments: [
        "Started a new job at Acme", "Training for a marathon", "Illustrator at Pixar",
        "Moved to Essex", "Took a taxi to Lisbon", "Owen got a puppy", "Watched Godzilla",
        "Learning to spray paint", "Rental car in Tahoe", "Building a treehouse",
    ])
    func harmlessHooksPass(text: String) {
        #expect(!SensitiveTopicFilter.isSensitive(text))
        #expect(MemoryHookPolicy.sanitize([text]) == [text])
    }

    @Test func sanitizeEnforcesLengthDedupAndCount() {
        let exactly40 = String(repeating: "a", count: 40)
        let tooLong = String(repeating: "b", count: 41)
        let result = MemoryHookPolicy.sanitize([
            "", "   ", tooLong, exactly40, "Learning to surf", "learning  TO surf", "Hiking\nthe PCT",
            "One more",
        ])
        #expect(result == [exactly40, "Learning to surf", "Hiking the PCT"])
    }

    @Test func makeHooksStampsSourceOwnerAndExpiry() {
        let person = PersonID()
        let now = Fixture.t0
        let hooks = MemoryHookPolicy.makeHooks(for: person, texts: ["Learning to surf"], now: now)
        #expect(hooks.count == 1)
        #expect(hooks[0].personID == person)
        #expect(hooks[0].source == .onDeviceSummary)
        #expect(hooks[0].createdAt == now)
        #expect(hooks[0].expiresAt == now.addingTimeInterval(30 * 24 * 60 * 60))
    }
}
