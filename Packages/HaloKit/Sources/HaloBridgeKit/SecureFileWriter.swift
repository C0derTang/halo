import Darwin
import Foundation

public enum SecureFileWriterError: Error, Equatable, CustomStringConvertible {
    /// A system call failed. The destination is untouched.
    case posix(operation: String, path: String, code: Int32)
    /// The file was renamed into place and is complete, but opening or fsyncing the parent
    /// directory failed afterwards, so the rename's durability across a crash is unconfirmed.
    /// Callers may treat the output as written; do not retry as if nothing happened.
    case durabilityUnconfirmed(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case .posix(let op, let path, let code):
            return "\(op) \(path) failed: \(String(cString: strerror(code)))"
        case .durabilityUnconfirmed(let op, let path, let code):
            let reason = String(cString: strerror(code))
            return "file written, but \(op) \(path) failed (durability unconfirmed): \(reason)"
        }
    }
}

/// Writes owner-only (0600) files atomically: the data goes to a temp file created 0600 with
/// `O_EXCL` in the destination directory, is fsynced, then `rename(2)`d over the destination, and
/// the parent directory is fsynced so the rename survives a crash.
/// Readers see either the old file or the complete new one, never a partial or world-readable
/// file. On failure the temp file is removed and the destination is untouched, except for
/// `durabilityUnconfirmed`: the complete file is already in place but the directory fsync failed.
public enum SecureFileWriter {
    static let tempPrefix = ".halo-tmp-"

    public static func write(_ data: Data, to url: URL) throws(SecureFileWriterError) {
        let dest = url.standardizedFileURL
        let dir = dest.deletingLastPathComponent()
        let temp = dir.appendingPathComponent("\(tempPrefix)\(dest.lastPathComponent).\(UUID().uuidString)")

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw .posix(operation: "create", path: temp.path, code: errno) }
        var committed = false
        defer {
            if !committed { unlink(temp.path) }
        }
        do {
            defer { close(fd) }
            // umask can only clear bits, but set the mode explicitly anyway.
            guard fchmod(fd, 0o600) == 0 else {
                throw SecureFileWriterError.posix(operation: "chmod", path: temp.path, code: errno)
            }
            // Non-throwing closure: typed throws through `withUnsafeBytes` needs Swift 6.3+.
            var writeError: SecureFileWriterError?
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        writeError = .posix(operation: "write", path: temp.path, code: errno)
                        return
                    }
                    offset += n
                }
            }
            if let writeError { throw writeError }
            guard fsync(fd) == 0 else {
                throw SecureFileWriterError.posix(operation: "fsync", path: temp.path, code: errno)
            }
        }
        guard rename(temp.path, dest.path) == 0 else {
            throw .posix(operation: "rename", path: dest.path, code: errno)
        }
        committed = true
        // Make the rename itself durable: fsync the parent directory so a crash cannot lose it.
        let dirFD = open(dir.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard dirFD >= 0 else {
            throw .durabilityUnconfirmed(operation: "open directory", path: dir.path, code: errno)
        }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else {
            throw .durabilityUnconfirmed(operation: "fsync directory", path: dir.path, code: errno)
        }
    }
}
