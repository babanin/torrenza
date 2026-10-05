import Foundation
import Testing
import TorrentCore
@testable import TorrentStorage

extension TorrentDiskTests {
    @Test func refreshPreparationRejectsUnownedAndMissingPayloadBeforeCreatingFiles() async throws {
        for missing in [false, true] {
            let root = try folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let ownedURL = root.appendingPathComponent("z-owned")
            try Data([1, 2, 3, 4]).write(to: ownedURL)
            let signature = try #require(await TorrentDisk.currentSignature(destination: root, path: ["z-owned"]))
            if missing { try FileManager.default.removeItem(at: ownedURL) }
            let files = [TorrentFile(index: 0, path: ["a-new"], length: 4, offset: 0), TorrentFile(index: 1, path: ["z-owned"], length: 4, offset: 4)]
            let disk = try TorrentDisk(metainfo: fixture(Data(repeating: 0, count: 8), pieceLength: 4, files: files), destination: root, selectedFiles: [0, 1], allowExisting: true, allowedExistingSignatures: missing ? [signature] : [])
            await #expect(throws: TorrentError.self) { try await disk.prepare() }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a-new").path))
            if missing { #expect(!FileManager.default.fileExists(atPath: ownedURL.path)) }
            else { #expect(try Data(contentsOf: ownedURL) == Data([1, 2, 3, 4])) }
            await disk.close()
        }
    }

    @Test func refreshPreparationRollbackPreservesReusedAndReplacedFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedURL = root.appendingPathComponent("owned"), newURL = root.appendingPathComponent("new")
        try Data([1, 2, 3, 4]).write(to: ownedURL)
        let signature = try #require(await TorrentDisk.currentSignature(destination: root, path: ["owned"]))
        let files = [TorrentFile(index: 0, path: ["owned"], length: 4, offset: 0), TorrentFile(index: 1, path: ["new"], length: 4, offset: 4), TorrentFile(index: 2, path: ["discard"], length: 4, offset: 8)]
        let disk = try TorrentDisk(metainfo: fixture(Data(repeating: 0, count: 12), pieceLength: 4, files: files), destination: root, selectedFiles: [0, 1, 2], allowExisting: true, allowedExistingSignatures: [signature])
        try await disk.prepare()
        // Moving the created inode avoids possible inode reuse during replacement.
        try FileManager.default.moveItem(at: newURL, to: root.appendingPathComponent("original-created"))
        try Data([9, 9, 9, 9]).write(to: newURL)
        let rollback = Task { await disk.rollbackPreparation() }
        rollback.cancel()
        await rollback.value
        #expect(try Data(contentsOf: ownedURL) == Data([1, 2, 3, 4]))
        #expect(try Data(contentsOf: newURL) == Data([9, 9, 9, 9]))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("discard").path))
    }
}
