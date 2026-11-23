import Foundation

/// Writes synthetic typedstream archives shaped like chat.db `attributedBody` blobs (an archived
/// `NSAttributedString` with one attribute run). Synthetic text only; no real messages.
///
/// Mirrors the format notes on `TypedStreamDecoder`: shared strings and objects/classes live in
/// separate back-reference tables, references are `index - 110`, and an object is registered when
/// its `0x84` is written, before its class chain.
struct TypedStreamWriter {
    private(set) var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03]
    private var strings: [String: Int] = [:]
    private var classes: [String: Int] = [:]
    private var tableCount = 0

    mutating func int(_ v: Int) {
        if (-110...127).contains(v) {
            bytes.append(UInt8(bitPattern: Int8(v)))
        } else if let v16 = Int16(exactly: v) {
            bytes.append(0x81)
            bytes += withUnsafeBytes(of: v16.littleEndian, Array.init)
        } else {
            bytes.append(0x82)
            bytes += withUnsafeBytes(of: Int32(v).littleEndian, Array.init)
        }
    }

    mutating func sharedString(_ s: String) {
        if let i = strings[s] {
            int(i - 110)
        } else {
            strings[s] = strings.count
            bytes.append(0x84)
            int(s.utf8.count)
            bytes += Array(s.utf8)
        }
    }

    /// Writes a class chain, e.g. `[("NSString", 1), ("NSObject", 0)]`.
    mutating func classChain(_ chain: [(name: String, version: Int)]) {
        guard let first = chain.first else {
            bytes.append(0x85)
            return
        }
        if let i = classes[first.name] {
            int(i - 110)
            return
        }
        classes[first.name] = tableCount
        tableCount += 1
        bytes.append(0x84)
        sharedString(first.name)
        int(first.version)
        classChain(Array(chain.dropFirst()))
    }

    mutating func beginObject(_ chain: [(name: String, version: Int)]) {
        bytes.append(0x84)
        tableCount += 1
        classChain(chain)
    }

    mutating func endObject() { bytes.append(0x86) }

    /// An `@` group holding an `NSString` (or `NSMutableString`) object.
    mutating func stringObject(_ text: String, mutable: Bool = false) {
        sharedString("@")
        beginObject(
            mutable
                ? [("NSMutableString", 1), ("NSString", 1), ("NSObject", 0)]
                : [("NSString", 1), ("NSObject", 0)])
        sharedString("+")
        int(text.utf8.count)
        bytes += Array(text.utf8)
        endObject()
    }

    /// A blob shaped like a real `message.attributedBody`.
    static func attributedBody(_ text: String, mutable: Bool = false) -> Data {
        var w = TypedStreamWriter()
        w.sharedString("@")
        w.beginObject(
            mutable
                ? [("NSMutableAttributedString", 0), ("NSAttributedString", 0), ("NSObject", 0)]
                : [("NSAttributedString", 0), ("NSObject", 0)])
        w.stringObject(text, mutable: mutable)
        // One attribute run covering the whole string: location, length, attributes dictionary.
        w.sharedString("iI")
        w.int(1)
        w.int(text.utf16.count)
        w.sharedString("@")
        w.beginObject([("NSDictionary", 0), ("NSObject", 0)])
        w.sharedString("i")
        w.int(1)
        w.stringObject("__kIMMessagePartAttributeName")
        w.sharedString("@")
        w.beginObject([("NSNumber", 0), ("NSValue", 0), ("NSObject", 0)])
        w.sharedString("i")
        w.int(0)
        w.endObject()
        w.endObject()
        w.endObject()
        return Data(w.bytes)
    }
}
