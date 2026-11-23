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
        // Gaps closed in review.
        "Came out as trans", "Is non-binary now", "Non binary and happy", "Back on her meds",
        "Quit drugs last year", "Drug test at work", "Her dad died", "Death in the family",
        "Six months sober", "Down with the flu", "Found Jesus", "Volunteers at the temple",
        "New pastor at work", "Training to be a priest", "Talked to the rabbi", "Met the imam",
        "Very spiritual lately", "Made a million dollars", "Owes 20 dollars", "Switched banks",
        "Paid in cash", "Got a big bonus", "Makes 50k now", "Sold it for 2.5m", "Started dating Sam",
        "New boyfriend Leo", "Moved in with girlfriend", "Getting divorced", "Ex-boyfriend moved",
        // Stay strict after the false-positive fixes.
        "The rabbi visited", "Rabbis at the dinner", "Got a 50k raise", "Earns 50k a year",
        "Has a 2m house",
        "Got a 5k raise", "Wanted a 10k bonus", "Paid the 5k fee", "Got a 50k run", "Makes 7k race bonus",
    ])
    func sensitiveTopicsAreRejected(text: String) {
        #expect(SensitiveTopicFilter.isSensitive(text))
        #expect(MemoryHookPolicy.sanitize([text]).isEmpty)
    }

    @Test(arguments: [
        "Started a new job at Acme", "Training for a marathon", "Illustrator at Pixar",
        "Moved to Essex", "Took a taxi to Lisbon", "Owen got a puppy", "Watched Godzilla",
        "Learning to spray paint", "Rental car in Tahoe", "Building a treehouse",
        "Transferred to the Berlin office", "Fluent in Portuguese", "Loves cashews",
        "Binary search nerd", "Riverbank picnic fan", "Rafting the rapids",
        // False positives fixed in #71.
        "Rabbit hole fan", "Needs a ids badge", "Ran a 5k", "Ran the 10k", "Charity 5k run",
        "Weekend 10k race", "Maintains Node.js packages", "Fan of Vue.js", "Writes Next.js apps",
        "Wrote main.py and util.rs", "Hacks on app.swift",
    ])
    func harmlessHooksPass(text: String) {
        #expect(!SensitiveTopicFilter.isSensitive(text))
        #expect(MemoryHookPolicy.sanitize([text]) == [text])
    }

    @Test(arguments: [
        "Blog: https://example.com", "Check www.example.org", "Email ana@example.com",
        "Now at acme.io", "Number is 5550001", "Call 555-000-1234", "Call (555) 000 1234",
        "Zip code 94110", "ftp://files", "DM me @ana_lima", "Reads news.ycombinator.com",
        "Runs acme.tokyo", "See node.js and acme.dev", "Reads blog.joe.com", "Mail mail.foo.com",
        "Is john.doe.net", "Visit acme.pro", "Visit acme.vip", "Try bob.xxx", "Uses x.js.com",
    ])
    func linksEmailsAndPhoneNumbersAreRejected(text: String) {
        #expect(MemoryHookPolicy.containsContactOrLink(text))
        #expect(MemoryHookPolicy.sanitize([text]).isEmpty)
    }

    @Test(arguments: ["Moved to St. Louis", "Class of 2019", "Ran 3 races in May", "Has 2 kids"])
    func ordinaryPunctuationAndShortNumbersPass(text: String) {
        #expect(!MemoryHookPolicy.containsContactOrLink(text))
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
