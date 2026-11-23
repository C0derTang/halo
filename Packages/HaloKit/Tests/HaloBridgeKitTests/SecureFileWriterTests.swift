import Foundation
import Testing

@testable import HaloBridgeKit

@Suite struct SecureFileWriterTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-writer-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func permissions(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func leftovers(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(SecureFileWriter.tempPrefix) }
    }

    @Test func writesOwnerOnlyFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.halodigest")
        try SecureFileWriter.write(Data("hello".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try permissions(url) == 0o600)
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func atomicallyReplacesExistingWorldReadableFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.halodigest")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let big = Data(repeating: 0xAB, count: 1 << 20)
        try SecureFileWriter.write(big, to: url)
        #expect(try Data(contentsOf: url) == big)
        #expect(try permissions(url) == 0o600)  // rename replaced the inode, not its mode
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func emptyData() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty")
        try SecureFileWriter.write(Data(), to: url)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func failureLeavesNothingBehind() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Missing directory: temp file cannot be created.
        let missing = dir.appendingPathComponent("nope/out.halodigest")
        #expect(throws: SecureFileWriterError.self) { try SecureFileWriter.write(Data([1]), to: missing) }
        // Destination is a non-empty directory: rename fails after the temp file was written.
        let blocker = dir.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(
            at: blocker.appendingPathComponent("child"), withIntermediateDirectories: true)
        #expect(throws: SecureFileWriterError.self) { try SecureFileWriter.write(Data([1]), to: blocker) }
        #expect(try leftovers(in: dir).isEmpty)
    }
}

@Suite struct SecureFileWriterDirectorySyncTests {
    @Test func succeedsAndLeavesNoTempFilesAfterDirectoryFsync() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-dirsync-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.halodigest")
        try SecureFileWriter.write(Data("a".utf8), to: url)
        try SecureFileWriter.write(Data("b".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("b".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.halodigest"])
    }
}
