import Foundation
import HaloCore

/// Hand-rolled argument parsing for `halo-bridge` (ArgumentParser is not available).
public enum BridgeCLI {
    public static let usage =
        "usage: halo-bridge digest [--db <chat.db>] --out <file> [--now <iso8601>] [--region <US|GB|...>]"

    struct Options {
        var db = ChatDatabaseReader.defaultURL
        var out: String
        var now = Date()
        var region = "US"
    }

    struct UsageError: Error { var message: String }

    static func parse(_ args: [String]) throws -> Options {
        guard args.first == "digest" else { throw UsageError(message: "expected subcommand 'digest'") }
        var db: String?
        var out: String?
        var now: Date?
        var region: String?
        var i = 1
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(message: "\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--db": db = try value("--db")
            case "--out": out = try value("--out")
            case "--region": region = try value("--region")
            case "--now":
                let s = try value("--now")
                guard let d = ISO8601DateFormatter().date(from: s) else {
                    throw UsageError(message: "--now must be ISO-8601, e.g. 2026-11-23T12:00:00Z")
                }
                now = d
            default: throw UsageError(message: "unknown argument \(args[i])")
            }
            i += 1
        }
        guard let out else { throw UsageError(message: "--out is required") }
        var o = Options(out: out)
        if let db { o.db = URL(fileURLWithPath: (db as NSString).expandingTildeInPath) }
        if let now { o.now = now }
        if let region { o.region = region }
        return o
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Runs the CLI and returns the process exit code. Diagnostics go to `errorOutput`.
    public static func run(
        arguments: [String],
        errorOutput: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch let e as UsageError {
            errorOutput("halo-bridge: \(e.message)\n\(usage)")
            return 64
        } catch {
            errorOutput("\(error)")
            return 64
        }
        do {
            let reader = try ChatDatabaseReader(url: options.db)
            let records = try reader.messageRecords()
            let digest = DigestBuilder(normalizer: HandleNormalizer(region: options.region))
                .build(records: records, now: options.now)
            let data = try encoder().encode(digest)
            try data.write(to: URL(fileURLWithPath: options.out), options: .atomic)
            return 0
        } catch let e as ChatDatabaseError {
            errorOutput("halo-bridge: \(e)")
            return 1
        } catch {
            errorOutput("halo-bridge: \(error)")
            return 1
        }
    }
}
