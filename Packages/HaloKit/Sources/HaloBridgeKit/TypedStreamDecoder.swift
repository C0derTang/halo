import Foundation

/// Minimal reader for Apple "typedstream" archives (the legacy `NSArchiver` format), used to pull
/// the plain string out of chat.db's `message.attributedBody` (an archived `NSAttributedString`).
///
/// Clean-room implementation written from public descriptions of the NeXTSTEP/Apple typedstream
/// format. It parses just enough of the object graph to reach the first `NSString` (or subclass)
/// payload, which in an archived attributed string is its text, and stops there.
///
/// Robustness: every read is bounds-checked, lengths and references are validated, and nesting is
/// capped, so malformed or hostile input returns nil instead of trapping. It never logs or throws
/// message content.
///
/// Format summary (all multi-byte integers little-endian):
/// - Header: streamer version byte (4), length-prefixed signature `streamtyped`, system version int.
/// - Integers: one signed byte, or `0x81` + Int16, or `0x82` + Int32. `0x83` introduces a real.
/// - Tags: `0x84` new definition, `0x85` nil, `0x86` end of object. Any other value in a
///   reference position is a back-reference: index = value + 110 (so `0x92` is index 0).
/// - Shared strings (type encodings, class names) live in one table; objects and classes share a
///   second table. An object is added when its `0x84` is read, before its class chain.
/// - An object is `0x84`, its class chain (`0x84` name version superclass… ending in `0x85`, or a
///   back-reference), then typed-value groups (a type-encoding shared string followed by one value
///   per type character) until `0x86`. `NSString` stores its UTF-8 bytes as a `+` value
///   (a length-prefixed byte run).
public enum TypedStreamDecoder {
    /// The plain text of an archived attributed string (or string), or nil if `data` is not a
    /// well-formed typedstream containing one.
    public static func plainText(from data: Data) -> String? {
        var reader = TypedStreamReader(bytes: [UInt8](data))
        return try? reader.firstString()
    }
}

struct TypedStreamReader {
    struct Malformed: Error {}

    static let streamerVersion: UInt8 = 4
    static let signature = Array("streamtyped".utf8)
    static let maxDepth = 32
    static let referenceBase = -110

    enum Tag {
        static let int16: UInt8 = 0x81
        static let int32: UInt8 = 0x82
        static let real: UInt8 = 0x83
        static let new: UInt8 = 0x84
        static let null: UInt8 = 0x85
        static let endOfObject: UInt8 = 0x86
    }

    /// Entries of the shared object/class reference table.
    enum Entry {
        /// An object whose class chain is still being read, or that is not a string.
        case object
        /// `isString` is resolved once, when the class is defined (its own name, or a string
        /// superclass), so per-object lookups are O(1) however long a crafted chain is.
        case classDef(isString: Bool)
    }

    let bytes: [UInt8]
    var pos = 0
    var strings: [[UInt8]] = []
    var table: [Entry] = []
    var depth = 0
    var found: String?

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// Parses the header and top-level values until the first string payload is found.
    mutating func firstString() throws -> String {
        try readHeader()
        while pos < bytes.count {
            try readGroup(inStringObject: false)
            if let found { return found }
        }
        throw Malformed()
    }

    // MARK: Primitives

    mutating func readByte() throws -> UInt8 {
        guard pos < bytes.count else { throw Malformed() }
        defer { pos += 1 }
        return bytes[pos]
    }

    func peek() throws -> UInt8 {
        guard pos < bytes.count else { throw Malformed() }
        return bytes[pos]
    }

    mutating func readBytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= bytes.count - pos else { throw Malformed() }
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }

    mutating func readLittleEndian(_ n: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in try readBytes(n).enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }

    /// A signed integer in the variable-length encoding.
    mutating func readInt() throws -> Int {
        let b = try readByte()
        switch b {
        case Tag.int16: return Int(Int16(truncatingIfNeeded: try readLittleEndian(2)))
        case Tag.int32: return Int(Int32(truncatingIfNeeded: try readLittleEndian(4)))
        case Tag.real: throw Malformed()
        default: return Int(Int8(bitPattern: b))
        }
    }

    /// A byte count. Lengths are never negative, so the wide forms are read unsigned.
    mutating func readLength() throws -> Int {
        let b = try readByte()
        switch b {
        case Tag.int16: return Int(try readLittleEndian(2))
        case Tag.int32: return Int(try readLittleEndian(4))
        case Tag.real: throw Malformed()
        default:
            let v = Int(Int8(bitPattern: b))
            guard v >= 0 else { throw Malformed() }
            return v
        }
    }

    mutating func readReference(count: Int) throws -> Int {
        let index = try readInt() - Self.referenceBase
        guard index >= 0, index < count else { throw Malformed() }
        return index
    }

    mutating func readHeader() throws {
        guard try readByte() == Self.streamerVersion else { throw Malformed() }
        guard Array(try readBytes(try readLength())) == Self.signature else { throw Malformed() }
        _ = try readInt()  // system version
    }

    // MARK: Shared strings, classes, objects

    /// A shared string: new (length-prefixed), nil, or a back-reference.
    mutating func readSharedString() throws -> [UInt8]? {
        switch try peek() {
        case Tag.new:
            pos += 1
            let s = Array(try readBytes(try readLength()))
            strings.append(s)
            return s
        case Tag.null:
            pos += 1
            return nil
        default:
            let index = try readReference(count: strings.count)
            return strings[index]
        }
    }

    /// A class chain; returns its table index, or nil for a nil class.
    mutating func readClass() throws -> Int? {
        try enter()
        defer { depth -= 1 }
        switch try peek() {
        case Tag.new:
            pos += 1
            let index = table.count
            table.append(.object)
            guard let name = try readSharedString() else { throw Malformed() }
            _ = try readInt()  // class version
            let superclass = try readClass()
            table[index] = .classDef(
                isString: Self.stringClassNames.contains(name) || isStringClass(superclass))
            return index
        case Tag.null:
            pos += 1
            return nil
        default:
            let index = try readReference(count: table.count)
            guard case .classDef = table[index] else { throw Malformed() }
            return index
        }
    }

    static let stringClassNames: Set<[UInt8]> = [Array("NSString".utf8), Array("NSMutableString".utf8)]

    /// O(1): `index` is nil or a `.classDef` (enforced by `readClass`).
    func isStringClass(_ index: Int?) -> Bool {
        guard let index, case .classDef(let isString) = table[index] else { return false }
        return isString
    }

    /// An object value: new (class chain + groups until end-of-object), nil, or a back-reference.
    mutating func readObject() throws {
        switch try peek() {
        case Tag.new:
            pos += 1
            try enter()
            defer { depth -= 1 }
            table.append(.object)
            // Read the class first: in `isStringClass(try readClass())` the receiver would be
            // captured before the mutating argument ran, and see a stale table.
            let cls = try readClass()
            let isString = isStringClass(cls)
            while try peek() != Tag.endOfObject {
                try readGroup(inStringObject: isString)
                if found != nil { return }
            }
            pos += 1
        case Tag.null:
            pos += 1
        default:
            _ = try readReference(count: table.count)
        }
    }

    mutating func enter() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw Malformed() }
    }

    // MARK: Typed values

    /// One type-encoding string followed by one value per type character.
    mutating func readGroup(inStringObject: Bool) throws {
        guard let types = try readSharedString(), !types.isEmpty else { throw Malformed() }
        for type in types {
            try readValue(type: type, inStringObject: inStringObject)
            if found != nil { return }
        }
    }

    mutating func readValue(type: UInt8, inStringObject: Bool) throws {
        switch type {
        case UInt8(ascii: "@"):
            try readObject()
        case UInt8(ascii: "#"):
            _ = try readClass()
        case UInt8(ascii: "*"), UInt8(ascii: "%"), UInt8(ascii: ":"):
            _ = try readSharedString()
        case UInt8(ascii: "+"):
            let payload = try readBytes(try readLength())
            if inStringObject {
                guard let s = String(bytes: payload, encoding: .utf8) else { throw Malformed() }
                found = s
            }
        case UInt8(ascii: "c"), UInt8(ascii: "C"), UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "i"),
            UInt8(ascii: "I"), UInt8(ascii: "l"), UInt8(ascii: "L"), UInt8(ascii: "q"), UInt8(ascii: "Q"),
            UInt8(ascii: "B"):
            _ = try readInt()
        case UInt8(ascii: "f"), UInt8(ascii: "d"):
            if try peek() == Tag.real {
                pos += 1
                _ = try readBytes(type == UInt8(ascii: "f") ? 4 : 8)
            } else {
                _ = try readInt()
            }
        default:
            // Arrays, structs, unions and anything else are outside this minimal reader.
            throw Malformed()
        }
    }
}
