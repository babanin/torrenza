import Foundation
import Testing
import TorrentCore
@testable import TorrentStorage

struct OwnedFilesTests {
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func allSelectionPayloadsAndSidecarsAreRemovedButUnrelatedFilesRemain() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["first-selection", "second-selection", ".torrenza-old.parts", ".torrenza-new.parts"]
        var signatures: [DiskSignature] = []
        for name in names {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
            signatures.append(try #require(await TorrentDisk.currentSignature(destination: root, path: [name])))
        }
        try Data([9]).write(to: root.appendingPathComponent("unrelated"))
        try await TorrentDisk.validateOwnedFiles(destination: root, signatures: signatures, allowMissing: false)
        try FileManager.default.removeItem(at: root.appendingPathComponent(names[0]))
        try await TorrentDisk.validateOwnedFiles(destination: root, signatures: signatures)
        await #expect(throws: TorrentError.self) { try await TorrentDisk.validateOwnedFiles(destination: root, signatures: signatures, allowMissing: false) }
        try await TorrentDisk.removeOwnedFiles(destination: root, signatures: signatures)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["unrelated"])
    }

    @Test func replacedFileAbortsBeforeDeletingAnyOwnedFile() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a-owned"), second = root.appendingPathComponent("z-replaced")
        try Data([1]).write(to: first); try Data([2]).write(to: second)
        let a = try #require(await TorrentDisk.currentSignature(destination: root, path: ["a-owned"]))
        let z = try #require(await TorrentDisk.currentSignature(destination: root, path: ["z-replaced"]))
        try FileManager.default.moveItem(at: second, to: root.appendingPathComponent("original"))
        try Data([9]).write(to: second)
        await #expect(throws: TorrentError.self) { try await TorrentDisk.removeOwnedFiles(destination: root, signatures: [a, z]) }
        #expect(try Data(contentsOf: first) == Data([1])); #expect(try Data(contentsOf: second) == Data([9]))
    }

    @Test func ownershipAllowsContentChangesButRejectsSymlinksAndTraversal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned"); try Data([1]).write(to: file)
        let original = try #require(await TorrentDisk.currentSignature(destination: root, path: ["owned"]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data([1, 2, 3, 4])); try handle.close()
        try await TorrentDisk.validateOwnedFiles(destination: root, signatures: [original], allowMissing: false)
        await #expect(throws: TorrentError.self) { try await TorrentDisk.currentSignature(destination: root, path: ["..", "outside"]) }
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("real"))
        await #expect(throws: TorrentError.self) { try await TorrentDisk.validateOwnedFiles(destination: root, signatures: [original]) }
        await #expect(throws: TorrentError.self) { try await TorrentDisk.removeOwnedFiles(destination: root, signatures: [original]) }
        #expect(try Data(contentsOf: root.appendingPathComponent("real")) == Data([1, 2, 3, 4]))
    }
}
