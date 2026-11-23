import Testing

@testable import HaloBridgeKit

@Suite struct HandleNormalizerTests {
    let us = HandleNormalizer()

    @Test(arguments: [
        ("(415) 555-0132", "+14155550132"),
        ("415-555-0132", "+14155550132"),
        ("4155550132", "+14155550132"),
        ("1 415 555 0132", "+14155550132"),
        ("+1 (415) 555-0132", "+14155550132"),
        ("+44 7700 900123", "+447700900123"),
        ("0044 7700 900123", "+447700900123"),
        ("Jane.Doe@Example.COM", "jane.doe@example.com"),
        ("  me@x.io ", "me@x.io"),
        ("12345", "12345"),
        ("urn:biz:ABC", "urn:biz:abc"),
    ])
    func usDefault(input: String, expected: String) {
        #expect(us.normalize(input) == expected)
    }

    @Test func configurableRegion() {
        let gb = HandleNormalizer(region: "GB")
        #expect(gb.normalize("07700 900123") == "+447700900123")
        #expect(gb.normalize("+1 415 555 0132") == "+14155550132")
        #expect(gb.normalize("447700900123") == "+447700900123")
    }

    @Test func idempotent() {
        let once = us.normalize("(415) 555-0132")
        #expect(us.normalize(once) == once)
    }
}
