import Foundation
import Testing

@testable import HaloBridgeKit

/// Synthetic blobs only: hand-written hex and `TypedStreamWriter` output.
@Suite struct TypedStreamDecoderTests {
    static let header: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03]

    func decode(_ bytes: [UInt8]) -> String? { TypedStreamDecoder.plainText(from: Data(bytes)) }

    /// Hand-written bytes (independent of `TypedStreamWriter`) in the real attributedBody shape.
    static let handWrittenHi: [UInt8] =
        header + [0x84, 0x01, 0x40]  // type "@"
        + [0x84, 0x84, 0x84, 0x12] + Array("NSAttributedString".utf8) + [0x00]  // obj 0, class 1
        + [0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85]  // class 2, end of chain
        + [0x92]  // type ref 0 = "@"
        + [0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94]  // obj 3, class 4 : ref 2
        + [0x84, 0x01, 0x2B, 0x02, 0x68, 0x69, 0x86]  // "+" length 2 "hi", end of object
        + [0x84, 0x02, 0x69, 0x49, 0x01, 0x02, 0x86]  // "iI" run, end of root

    @Test func decodesHandWrittenAttributedBody() {
        #expect(decode(Self.handWrittenHi) == "hi")
    }

    @Test func writerMatchesHandWrittenShape() {
        let blob = [UInt8](TypedStreamWriter.attributedBody("hi"))
        let prefix = Self.handWrittenHi.count - 7  // up to and including the string's end-of-object
        #expect(Array(blob.prefix(prefix)) == Array(Self.handWrittenHi.prefix(prefix)))
    }

    @Test(arguments: [
        "Hello there",
        "héllo wörld",
        "See you at 7 👋🏽",
        "家族 👨‍👩‍👧‍👦 🇯🇵 مرحبا",
        "line one\nline two\ttab",
        "a",
    ])
    func roundTripsUnicode(_ text: String) {
        #expect(TypedStreamDecoder.plainText(from: TypedStreamWriter.attributedBody(text)) == text)
        #expect(
            TypedStreamDecoder.plainText(from: TypedStreamWriter.attributedBody(text, mutable: true)) == text)
    }

    @Test func emptyStringDecodesToEmpty() {
        #expect(TypedStreamDecoder.plainText(from: TypedStreamWriter.attributedBody("")) == "")
    }

    @Test func longLengthsUseWideIntegerForms() {
        let medium = String(repeating: "x", count: 300)  // 0x81 + Int16 length
        let long = String(repeating: "é", count: 20_000)  // 40 000 bytes: 0x82 + Int32 length
        #expect(TypedStreamDecoder.plainText(from: TypedStreamWriter.attributedBody(medium)) == medium)
        #expect(TypedStreamDecoder.plainText(from: TypedStreamWriter.attributedBody(long)) == long)
    }

    @Test func int16LengthAboveSignedRangeIsReadUnsigned() {
        let text = String(repeating: "y", count: 40_000)
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject([("NSString", 1), ("NSObject", 0)])
        w.sharedString("+")
        let bytes = w.bytes + [0x81, 0x40, 0x9C] + Array(text.utf8) + [0x86]  // 0x9C40 = 40 000
        #expect(decode(bytes) == text)
    }

    @Test func skipsScalarsNilsAndRealsBeforeTheString() {
        var w = TypedStreamWriter()
        w.sharedString("@")
        // obj 0; classes HaloTestContainer = 1, NSObject = 2
        w.beginObject([("HaloTestContainer", 0), ("NSObject", 0)])
        w.sharedString("ic")
        w.int(-5)
        w.int(1_000)
        var bytes = w.bytes
        bytes +=
            [0x84, 0x01, 0x64, 0x83]
            + withUnsafeBytes(of: (2.5 as Double).bitPattern.littleEndian, Array.init)
        bytes += [0x84, 0x01, 0x66, 0x03]  // "f": integral real written as a plain integer
        bytes += [0x92, 0x85]  // "@": nil object
        bytes += [0x84, 0x01, 0x2A, 0x84, 0x03] + Array("sel".utf8)  // "*": shared C string
        bytes += [0x92]  // "@"
        // obj 3, class 4 (NSString) whose superclass is a reference to NSObject (2).
        bytes += [0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94]
        bytes += [0x84, 0x01, 0x2B, 0x03] + Array("yes".utf8) + [0x86, 0x86]
        #expect(decode(bytes) == "yes")
    }

    @Test func nonStringObjectGivesNil() {
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject([("NSNumber", 0), ("NSValue", 0), ("NSObject", 0)])
        w.sharedString("i")
        w.int(42)
        w.endObject()
        #expect(decode(w.bytes) == nil)
    }

    @Test func plusValueOutsideAStringObjectIsIgnored() {
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject([("NSData", 0), ("NSObject", 0)])
        w.sharedString("+")
        w.int(3)
        let bytes = w.bytes + Array("abc".utf8) + [0x86]
        #expect(decode(bytes) == nil)
    }

    @Test func badHeadersGiveNil() {
        #expect(decode([]) == nil)
        #expect(decode(Self.header) == nil)
        var wrongVersion = Self.handWrittenHi
        wrongVersion[0] = 0x03
        #expect(decode(wrongVersion) == nil)
        var wrongSignature = Self.handWrittenHi
        wrongSignature[2] = UInt8(ascii: "S")
        #expect(decode(wrongSignature) == nil)
        #expect(decode(Array("plain text, not an archive".utf8)) == nil)
        #expect(decode(Array(repeating: 0, count: 64)) == nil)
    }

    @Test func truncatedInputNeverDecodesOrCrashes() {
        let blob = [UInt8](TypedStreamWriter.attributedBody("truncate me 🙂"))
        let stringEnd = Self.indexAfter(Array("truncate me 🙂".utf8), in: blob)
        for n in 0..<blob.count {
            let result = decode(Array(blob.prefix(n)))
            if n < stringEnd {
                #expect(result == nil, "prefix \(n)")
            } else {
                #expect(result == "truncate me 🙂", "prefix \(n)")
            }
        }
    }

    @Test func corruptedBytesNeverCrash() {
        let blob = [UInt8](TypedStreamWriter.attributedBody("mutate 🌍 me"))
        for i in blob.indices {
            for v in [0x00, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x92, 0xFF] as [UInt8] {
                var b = blob
                b[i] = v
                _ = decode(b)
            }
            var b = blob
            b.remove(at: i)
            _ = decode(b)
        }
    }

    @Test func randomGarbageNeverCrashes() {
        var rng = SplitMix64(seed: 0x4841_4C4F)
        for _ in 0..<3_000 {
            let n = Int(rng.next() % 200)
            let garbage = (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = decode(garbage)
            _ = decode(Self.header + garbage)  // past the header, into the object graph
        }
    }

    @Test func invalidUTF8PayloadGivesNil() {
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject([("NSString", 1), ("NSObject", 0)])
        w.sharedString("+")
        w.int(2)
        #expect(decode(w.bytes + [0xC3, 0x28, 0x86]) == nil)
    }

    @Test func oversizedLengthsGiveNil() {
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject([("NSString", 1), ("NSObject", 0)])
        w.sharedString("+")
        #expect(decode(w.bytes + [0x82, 0xFF, 0xFF, 0xFF, 0x7F] + Array("short".utf8)) == nil)
        #expect(decode(w.bytes + [0x82, 0xFF, 0xFF, 0xFF, 0xFF] + Array("short".utf8)) == nil)
        // A shared string claiming more bytes than exist.
        #expect(decode(Self.header + [0x84, 0x81, 0xFF, 0x7F, 0x40]) == nil)
    }

    @Test func danglingReferencesGiveNil() {
        #expect(decode(Self.header + [0x99]) == nil)  // type-string ref with empty table
        // Object whose class is a reference to a slot that does not exist.
        #expect(decode(Self.header + [0x84, 0x01, 0x40, 0x84, 0xA0]) == nil)
        // Class reference that points at an object, not a class.
        #expect(decode(Self.header + [0x84, 0x01, 0x40, 0x84, 0x92]) == nil)
    }

    @Test func deepNestingIsCappedWithoutStackOverflow() {
        // Objects nested inside objects: "@" { "@" { "@" { ... } } }
        var nested = Self.header + [0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x01, 0x41, 0x00, 0x85]
        for _ in 0..<50_000 { nested += [0x92, 0x84, 0x93] }
        #expect(decode(nested) == nil)

        // An endless superclass chain.
        var chain = Self.header + [0x84, 0x01, 0x40, 0x84]
        for i in 0..<50_000 { chain += [0x84, 0x84, 0x02, UInt8(65 + i % 26), UInt8(97 + i % 26), 0x00] }
        #expect(decode(chain) == nil)
    }

    @Test func nestingWithinTheCapStillDecodes() {
        // The string sits a few objects deep, as an attributed string inside a container.
        var bytes = Self.header + [0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x01, 0x41, 0x00, 0x85]
        for _ in 0..<5 { bytes += [0x92, 0x84, 0x93] }
        bytes += [0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x85]
        bytes += [0x84, 0x01, 0x2B, 0x04] + Array("deep".utf8) + [0x86]
        #expect(decode(bytes) == "deep")
    }

    static func indexAfter(_ needle: [UInt8], in haystack: [UInt8]) -> Int {
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start + needle.count
        }
        return haystack.count
    }
}

/// Deterministic PRNG so garbage tests are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
