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

    @Test func catchesHitsStraddlingWindowBoundariesInLongNotes() {
        // Pad so the sensitive word / number lands at many offsets, mid-note and at the end.
        let filler = "we walked around the park and talked"
        for pad in 0..<45 {
            let lead = String(repeating: "x", count: pad)
            let prefix = filler + " " + lead + " " + filler + " "
            #expect(MomentsPolicy.sanitize(prefix + "her surgery went well " + filler) == nil)
            #expect(MomentsPolicy.sanitize(prefix + "call 555 123 4567 " + filler) == nil)
            #expect(MomentsPolicy.sanitize(prefix + "visit acme.com " + filler) == nil)
        }
    }
}
