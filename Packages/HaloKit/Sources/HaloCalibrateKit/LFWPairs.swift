import Foundation

/// One image in the LFW (Labeled Faces in the Wild) directory layout: `<name>/<name>_<nnnn>.jpg`.
public struct LFWImageRef: Hashable, Comparable, Sendable {
    public var name: String
    public var number: Int

    public init(name: String, number: Int) {
        self.name = name
        self.number = number
    }

    /// Path relative to the extracted `lfw/` directory.
    public var relativePath: String {
        let digits = String(number)
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        return "\(name)/\(name)_\(padded).jpg"
    }

    public static func < (lhs: LFWImageRef, rhs: LFWImageRef) -> Bool {
        (lhs.name, lhs.number) < (rhs.name, rhs.number)
    }
}

/// One verification pair from an LFW `pairs.txt`.
public struct LFWPair: Hashable, Sendable {
    public var first: LFWImageRef
    public var second: LFWImageRef
    /// 0-based fold index (LFW's standard protocol has 10 folds).
    public var fold: Int

    public init(first: LFWImageRef, second: LFWImageRef, fold: Int) {
        self.first = first
        self.second = second
        self.fold = fold
    }

    /// Same person ("matched" pair) vs different people ("mismatched").
    public var isGenuine: Bool { first.name == second.name }
}

public enum LFWPairsError: Error, Equatable, Sendable {
    case emptyFile
    case badHeader(String)
    case badLine(number: Int)
    case countMismatch(expected: Int, actual: Int)
}

/// Parser for the LFW `pairs.txt` format.
///
/// Header: `<folds>\t<n>` (or a single `<n>` for the one-fold dev files). Then, per fold, `n` matched
/// lines `name i j` followed by `n` mismatched lines `name1 i name2 j`. Fields are whitespace-separated.
public enum LFWPairs {
    public static func parse(_ text: String) throws -> [LFWPair] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { throw LFWPairsError.emptyFile }
        let headerFields = fields(header).compactMap { Int($0) }
        guard headerFields.count == fields(header).count, headerFields.allSatisfy({ $0 > 0 }) else {
            throw LFWPairsError.badHeader(header)
        }
        let folds: Int
        let perClass: Int
        switch headerFields.count {
        case 1: (folds, perClass) = (1, headerFields[0])
        case 2: (folds, perClass) = (headerFields[0], headerFields[1])
        default: throw LFWPairsError.badHeader(header)
        }

        let body = lines.dropFirst()
        let expected = folds * 2 * perClass
        guard body.count == expected else {
            throw LFWPairsError.countMismatch(expected: expected, actual: body.count)
        }

        var pairs: [LFWPair] = []
        pairs.reserveCapacity(expected)
        for (offset, line) in body.enumerated() {
            let lineNumber = offset + 2
            let fold = offset / (2 * perClass)
            let isMatchedBlock = offset % (2 * perClass) < perClass
            let f = fields(line)
            let pair: LFWPair
            switch (f.count, isMatchedBlock) {
            case (3, true):
                guard let i = number(f[1]), let j = number(f[2]) else {
                    throw LFWPairsError.badLine(number: lineNumber)
                }
                pair = LFWPair(
                    first: LFWImageRef(name: f[0], number: i), second: LFWImageRef(name: f[0], number: j),
                    fold: fold)
            case (4, false):
                guard let i = number(f[1]), let j = number(f[3]), f[0] != f[2] else {
                    throw LFWPairsError.badLine(number: lineNumber)
                }
                pair = LFWPair(
                    first: LFWImageRef(name: f[0], number: i), second: LFWImageRef(name: f[2], number: j),
                    fold: fold)
            default:
                throw LFWPairsError.badLine(number: lineNumber)
            }
            pairs.append(pair)
        }
        return pairs
    }

    /// Every distinct image referenced by `pairs`, sorted.
    public static func images(in pairs: [LFWPair]) -> [LFWImageRef] {
        Set(pairs.flatMap { [$0.first, $0.second] }).sorted()
    }

    private static func fields(_ line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func number(_ field: String) -> Int? {
        guard let value = Int(field), value > 0 else { return nil }
        return value
    }
}
