import Testing

@testable import HaloAppCore

@Suite struct MomentsPolicyTests {
    @Test func acceptsPlainLongNote() {
        let note = "Loved hearing about her garden and the new puppy they adopted last weekend, too"
        #expect(note.count > 40)
        #expect(MomentsPolicy.sanitize(note) == note)
    }

    @Test func collapsesWhitespace() {
        #expect(MomentsPolicy.sanitize("a   b \n c") == "a b c")
    }

    @Test func rejectsSensitiveTopicDeepInNote() {
        let note = "We had a great catch up over coffee and then she mentioned her surgery next month"
        #expect(MomentsPolicy.sanitize(note) == nil)
    }

    @Test func rejectsLinksEmailsAndPhonesEvenPastTheHookLength() {
        let pad = "Great chat about the weekend hike and the long drive home, "
        #expect(MomentsPolicy.sanitize(pad + "see acme.com") == nil)
        #expect(MomentsPolicy.sanitize(pad + "mail me@x.org") == nil)
        #expect(MomentsPolicy.sanitize(pad + "call 555 123 4567") == nil)
        #expect(MomentsPolicy.sanitize(pad + "https://x.y/z") == nil)
    }

    @Test func rejectsEmptyAndOversizedWord() {
        #expect(MomentsPolicy.sanitize("   ") == nil)
        #expect(MomentsPolicy.sanitize(String(repeating: "a", count: 60)) == nil)
    }
}
