import Darwin
import Foundation

public enum SecureFileWriterError: Error, Equatable, CustomStringConvertible {
    case posix(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case .posix(let op, let path, let code):
            return "\(op) \(path) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Writes owner-only (0600) files atomically: the data goes to a temp file created 0600 with
/// `O_EXCL` in the destination directory, is fsynced, then `rename(2)`d over the destination.
/// Readers see either the old file or the complete new one, never a partial or world-readable
/// file. On failure the temp file is removed and the destination is untouched.
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
    }
}
