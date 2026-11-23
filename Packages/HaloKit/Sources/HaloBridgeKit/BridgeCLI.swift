import Foundation
import HaloCore

/// Hand-rolled argument parsing for `halo-bridge` (ArgumentParser is not available).
///
/// Invariant 6: the only way to write the digest unencrypted is the explicit debug command
/// `digest --plaintext`. `export` always seals to the paired phone's key.
public enum BridgeCLI {
    public static let usage = """
        usage:
          halo-bridge pair <payload>
              Pair with the phone whose pairing QR payload is <payload> (stored in the Keychain).
          halo-bridge export --out <file>.halodigest [--db <chat.db>] [--now <iso8601>] [--region <US|GB|...>]
              Read chat.db and write the digest encrypted to the paired phone.
          halo-bridge digest --plaintext --out <file> [--db <chat.db>] [--now <iso8601>] [--region <US|GB|...>]
              DEBUG ONLY: write the digest as UNENCRYPTED JSON.
        --region defaults to this Mac's region.
        """

    struct DigestOptions: Equatable {
        var db = ChatDatabaseReader.defaultURL
        var out: String
        var now = Date()
        /// Uppercased ISO region for `HandleNormalizer(region:)`; recorded in the envelope header.
        var region: String
    }

    enum Command: Equatable {
        case pair(payload: String)
        case export(DigestOptions)
        case plaintextDigest(DigestOptions)
    }

    struct UsageError: Error { var message: String }

    /// The Mac's region, falling back to US.
    static var localeRegion: String { Locale.current.region?.identifier ?? "US" }

    static func parse(_ args: [String], defaultRegion: String = localeRegion) throws -> Command {
        switch args.first {
        case "pair":
            guard args.count == 2 else { throw UsageError(message: "pair takes exactly one <payload>") }
            return .pair(payload: args[1])
        case "export":
            let o = try parseDigestOptions(
                Array(args.dropFirst()), allowPlaintext: false, defaultRegion: defaultRegion)
            guard URL(fileURLWithPath: o.out).pathExtension == DigestEnvelope.fileExtension else {
                throw UsageError(message: "--out must end in .\(DigestEnvelope.fileExtension)")
            }
            return .export(o)
        case "digest":
            let rest = Array(args.dropFirst())
            guard rest.contains("--plaintext") else {
                throw UsageError(
                    message:
                        "digest writes UNENCRYPTED JSON and needs --plaintext (debug only); use 'export' instead"
                )
            }
            return .plaintextDigest(
                try parseDigestOptions(rest, allowPlaintext: true, defaultRegion: defaultRegion))
        default:
            throw UsageError(message: "expected subcommand 'pair', 'export' or 'digest'")
        }
    }

    static func parseDigestOptions(_ args: [String], allowPlaintext: Bool, defaultRegion: String) throws
        -> DigestOptions
    {
        var db: String?
        var out: String?
        var now: Date?
        var region: String?
        var i = 0
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
            case "--plaintext" where allowPlaintext: break
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
        let resolvedRegion = (region ?? defaultRegion).uppercased()
        guard DigestEnvelope.isValidRegion(resolvedRegion) else {
            throw UsageError(message: "--region must be an ISO region code such as US or GB")
        }
        var o = DigestOptions(out: (out as NSString).expandingTildeInPath, region: resolvedRegion)
        if let db { o.db = URL(fileURLWithPath: (db as NSString).expandingTildeInPath) }
        if let now { o.now = now }
        return o
    }

    static func buildDigest(_ o: DigestOptions) throws -> InteractionDigest {
        let reader = try ChatDatabaseReader(url: o.db)
        let records = try reader.messageRecords()
        return DigestBuilder(normalizer: HandleNormalizer(region: o.region)).build(
            records: records, now: o.now)
    }

    public static func encoder() -> JSONEncoder { DigestCoding.encoder() }

    /// Runs the CLI and returns the process exit code. `keyStore` holds the paired phone's public
    /// key (`KeychainKeyStore.bridge` in the real binary; tests inject a fake).
    public static func run(
        arguments: [String],
        keyStore: any KeyStore,
        output: (String) -> Void = { print($0) },
        errorOutput: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        let command: Command
        do {
            command = try parse(arguments)
        } catch let e as UsageError {
            errorOutput("halo-bridge: \(e.message)\n\(usage)")
            return 64
        } catch {
            errorOutput("\(error)")
            return 64
        }
        do {
            switch command {
            case .pair(let raw):
                let payload = try PairingPayload(encoded: raw)
                try PairedPhone.save(payload, in: keyStore)
                output("Paired with phone key \(payload.keyID).")
            case .export(let o):
                // Check pairing before touching chat.db.
                guard let phone = try PairedPhone.load(from: keyStore) else { throw PairingError.notPaired }
                warnOnUnknownRegion(o, errorOutput)
                let digest = try buildDigest(o)
                let envelope = try DigestEnvelope.seal(digest, normalizerRegion: o.region, to: phone)
                try SecureFileWriter.write(envelope.serialized, to: URL(fileURLWithPath: o.out))
                output(
                    "Wrote \(o.out): \(digest.entries.count) conversations, sealed to phone key \(phone.keyID), region \(o.region)."
                )
            case .plaintextDigest(let o):
                warnOnUnknownRegion(o, errorOutput)
                errorOutput("halo-bridge: WARNING: writing UNENCRYPTED digest (debug only): \(o.out)")
                let data = try DigestCoding.encoder().encode(try buildDigest(o))
                try SecureFileWriter.write(data, to: URL(fileURLWithPath: o.out))
            }
            return 0
        } catch let e as PairingError {
            errorOutput("halo-bridge: \(e)")
            return 1
        } catch let e as ChatDatabaseError {
            errorOutput("halo-bridge: \(e)")
            return 1
        } catch {
            errorOutput("halo-bridge: \(error)")
            return 1
        }
    }

    static func warnOnUnknownRegion(_ o: DigestOptions, _ errorOutput: (String) -> Void) {
        if !HandleNormalizer.isKnownRegion(o.region) {
            errorOutput(
                "halo-bridge: no calling code known for region \(o.region); national-format numbers stay unnormalized. Pass --region to override."
            )
        }
    }
}
