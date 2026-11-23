import Testing

@testable import HaloCalibrateKit

// Synthetic pair lists in the LFW format; the names are made up.

@Test func imageRefFromDirectoryListing() {
    #expect(
        LFWImageRef(directory: "Person_A", fileName: "Person_A_0012.jpg")
            == LFWImageRef(name: "Person_A", number: 12))
    #expect(LFWImageRef(directory: "Person_A", fileName: "Person_B_0001.jpg") == nil)
    #expect(LFWImageRef(directory: "Person_A", fileName: "Person_A_0001.png") == nil)
    #expect(LFWImageRef(directory: "Person_A", fileName: "Person_A_.jpg") == nil)
    #expect(LFWImageRef(directory: "Person_A", fileName: "Person_A_0000.jpg") == nil)
    #expect(LFWImageRef(directory: "Person_A", fileName: ".DS_Store") == nil)
    // Round trip with the path the pair list uses.
    let ref = LFWImageRef(name: "Person_A", number: 3)
    let parts = ref.relativePath.split(separator: "/").map(String.init)
    #expect(LFWImageRef(directory: parts[0], fileName: parts[1]) == ref)
}

private let twoFolds = """
    2\t1
    Person_A\t1\t2
    Person_B\t1\tPerson_C\t3
    Person_D\t2\t10
    Person_A 4 Person_D 1
    """

@Test func parsesFoldsAndPairKinds() throws {
    let pairs = try LFWPairs.parse(twoFolds)
    #expect(pairs.count == 4)
    #expect(pairs.map(\.fold) == [0, 0, 1, 1])
    #expect(pairs.map(\.isGenuine) == [true, false, true, false])
    #expect(pairs[1].first == LFWImageRef(name: "Person_B", number: 1))
    #expect(pairs[1].second == LFWImageRef(name: "Person_C", number: 3))
    #expect(pairs[3].second == LFWImageRef(name: "Person_D", number: 1))
}

@Test func imagePathsAreZeroPadded() {
    #expect(LFWImageRef(name: "Person_A", number: 7).relativePath == "Person_A/Person_A_0007.jpg")
    #expect(LFWImageRef(name: "Person_A", number: 123).relativePath == "Person_A/Person_A_0123.jpg")
    #expect(LFWImageRef(name: "Person_A", number: 12345).relativePath == "Person_A/Person_A_12345.jpg")
}

@Test func singleNumberHeaderIsOneFold() throws {
    let pairs = try LFWPairs.parse("1\nPerson_A\t1\t2\nPerson_A\t1\tPerson_B\t1\n")
    #expect(pairs.map(\.fold) == [0, 0])
}

@Test func distinctImagesAreSortedAndDeduplicated() throws {
    let refs = LFWPairs.images(in: try LFWPairs.parse(twoFolds))
    #expect(refs.count == 8)  // A1 A2 A4 B1 C3 D1 D2 D10
    #expect(refs == refs.sorted())
    #expect(Set(refs).count == refs.count)
}

@Test func rejectsMalformedLists() {
    #expect(throws: LFWPairsError.emptyFile) { try LFWPairs.parse("\n\n") }
    #expect(throws: LFWPairsError.badHeader("ten 300")) { try LFWPairs.parse("ten 300\n") }
    #expect(throws: LFWPairsError.countMismatch(expected: 4, actual: 3)) {
        try LFWPairs.parse("2\t1\nA\t1\t2\nA\t1\tB\t1\nA\t1\t2\n")
    }
    // A mismatched-pair line inside the matched block.
    #expect(throws: LFWPairsError.badLine(number: 2)) { try LFWPairs.parse("1\nA\t1\tB\t2\nA\t1\tB\t1\n") }
    // A "mismatched" pair of the same person, and a zero image number.
    #expect(throws: LFWPairsError.badLine(number: 3)) { try LFWPairs.parse("1\nA\t1\t2\nA\t1\tA\t2\n") }
    #expect(throws: LFWPairsError.badLine(number: 2)) { try LFWPairs.parse("1\nA\t0\t2\nA\t1\tB\t2\n") }
}
