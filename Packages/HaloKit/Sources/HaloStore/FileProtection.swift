import Foundation

/// iOS Data Protection for the store's files. No-ops on other platforms (macOS host tests).
enum FileProtection {
    /// The main database file plus the SQLite WAL-mode siblings.
    static func databaseFilePaths(for path: String) -> [String] {
        [path, path + "-wal", path + "-shm"]
    }

    /// Creates the (empty) database file with `.complete` protection before SQLite opens it, so the
    /// file is never on disk with a weaker protection class. The parent directory also gets
    /// `.complete`, so `-wal`/`-shm` files SQLite (re)creates there inherit it, for custom paths too.
    static func prepareDatabaseFile(at path: String) throws {
        #if os(iOS)
            let manager = FileManager.default
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory)
            }
            if !manager.fileExists(atPath: path) {
                guard
                    manager.createFile(
                        atPath: path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]
                    )
                else { throw CocoaError(.fileWriteUnknown) }
            }
        #endif
    }

    /// Applies `.complete` to the database file and any existing `-wal`/`-shm` siblings.
    static func protectDatabaseFiles(at path: String) throws {
        #if os(iOS)
            let manager = FileManager.default
            for file in databaseFilePaths(for: path) where manager.fileExists(atPath: file) {
                try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file)
            }
        #endif
    }

    /// `Application Support/HaloStore`, created and (on iOS) protected with `.complete`, so files
    /// SQLite recreates inside it inherit the protection class.
    static func defaultDirectory() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("HaloStore", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        return directory
    }
}
