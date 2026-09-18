import Foundation
import CryptoKit
import Testing
import TorrentCore
@testable import TorrentStorage

struct TorrentDiskTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func fixture(_ payload: Data, pieceLength: Int, files: [TorrentFile]) -> TorrentMetainfo {
        var hashes: [Data] = []
        for offset in stride(from: 0, to: payload.count, by: pieceLength) { hashes.append(Data(Insecure.SHA1.hash(data: payload.subdata(in: offset..<min(payload.count, offset + pieceLength))))) }
        return TorrentMetainfo(infoHash: Data(repeating: 0x12, count: 20), rawInfo: Data(), name: "Root", pieceLength: pieceLength, pieceHashes: hashes, files: files, trackerTiers: [], isPrivate: false, isMultiFile: files.count > 1)
    }

    @Test func crossFileWritesPaddingAndProgress() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 0, 0, 4, 5, 6])
        let files = [TorrentFile(index: 0, path: ["Root", "a"], length: 3, offset: 0), TorrentFile(index: 1, path: ["Root", ".pad", "2"], length: 2, offset: 3, isPadding: true), TorrentFile(index: 2, path: ["Root", "sub", "b"], length: 3, offset: 5)]
        let disk = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: files), destination: root, selectedFiles: [0, 2])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes)
        #expect(try await disk.read(offset: 0, length: 8) == bytes)
        #expect(try await disk.verifyPiece(0)); #expect(try await disk.verifyPiece(1))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Root/.pad").path))
        var verified = PieceBitset(count: 2); verified[0] = true
        let snapshots = await disk.fileSnapshots(verified: verified)
        #expect(snapshots.map(\.verifiedBytes) == [3, 0])
        try await disk.flush(); await disk.close()
        #expect(try Data(contentsOf: root.appendingPathComponent("Root/sub/b")) == Data([4, 5, 6]))
    }

    @Test func selectiveBoundarySidecarAndResume() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<24).map(UInt8.init))
        let files = [TorrentFile(index: 0, path: ["Root", "skip-first"], length: 3, offset: 0), TorrentFile(index: 1, path: ["Root", "wanted"], length: 6, offset: 3), TorrentFile(index: 2, path: ["Root", "skip-last"], length: 15, offset: 9)]
        let meta = fixture(bytes, pieceLength: 8, files: files)
        let disk = try TorrentDisk(metainfo: meta, destination: root, selectedFiles: [1])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes.prefix(16)); try await disk.flush()
        #expect(try await disk.verifyPiece(0)); #expect(try await disk.verifyPiece(1))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Root/skip-first").path))
        let signatures = try await disk.signatures()
        #expect(signatures.first(where: { $0.path.hasSuffix(".parts") })?.size == 10)
        await disk.close()
        let resumed = try TorrentDisk(metainfo: meta, destination: root, selectedFiles: [1], allowExisting: true)
        try await resumed.prepare()
        #expect(try await resumed.signatures() == signatures)
        #expect(try await resumed.verifyPiece(1))
        await #expect(throws: TorrentError.self) { try await resumed.read(offset: 16, length: 8) }
        await resumed.close()
    }

    @Test func existingPayloadIsPreservedAndSymlinkRejected() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4]); let files = [TorrentFile(index: 0, path: ["file"], length: 4, offset: 0)]
        let target = root.appendingPathComponent("file"); try bytes.write(to: target)
        let disk = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: files), destination: root, selectedFiles: [0])
        await #expect(throws: TorrentError.self) { try await disk.prepare() }
        #expect(try Data(contentsOf: target) == bytes)
        try FileManager.default.removeItem(at: target)
        let outside = root.appendingPathComponent("outside"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let resume = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: files), destination: root, selectedFiles: [0], allowExisting: true)
        await #expect(throws: TorrentError.self) { try await resume.prepare() }
        #expect(try Data(contentsOf: outside) == bytes)
    }

    @Test func rejectsTraversalCollisionsAndReplacement() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4])
        for path in [["..", "outside"], ["/absolute"], ["a/b"], ["a\0b"], ["."]] {
            #expect(throws: TorrentError.self) { try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: [TorrentFile(index: 0, path: path, length: 4, offset: 0)]), destination: root, selectedFiles: [0]) }
        }
        let collisions = [TorrentFile(index: 0, path: ["File"], length: 2, offset: 0), TorrentFile(index: 1, path: ["file"], length: 2, offset: 2)]
        #expect(throws: TorrentError.self) { try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: collisions), destination: root, selectedFiles: [0, 1]) }
        let disk = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 4, files: [TorrentFile(index: 0, path: ["file"], length: 4, offset: 0)]), destination: root, selectedFiles: [0])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes)
        let payload = root.appendingPathComponent("file")
        try FileManager.default.moveItem(at: payload, to: root.appendingPathComponent("old"))
        let replacement = Data([9, 9, 9, 9]); try replacement.write(to: payload)
        await #expect(throws: TorrentError.self) { try await disk.write(offset: 0, data: bytes) }
        await #expect(throws: TorrentError.self) { try await disk.deleteFiles() }
        #expect(try Data(contentsOf: payload) == replacement)
        await disk.close()
    }

    @Test func streamHashLargePieceAndDetectCorruption() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        let meta = fixture(bytes, pieceLength: 200_000, files: [TorrentFile(index: 0, path: ["large"], length: 200_000, offset: 0)])
        let disk = try TorrentDisk(metainfo: meta, destination: root, selectedFiles: [0])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes)
        #expect(try await disk.verifyPiece(0))
        try await disk.write(offset: 131_071, data: Data([0xff]))
        #expect(try await disk.verifyPiece(0)) // The original byte is also ff.
        try await disk.write(offset: 131_071, data: Data([0]))
        #expect(try await !disk.verifyPiece(0))
        await #expect(throws: TorrentError.self) { try await disk.read(offset: -1, length: 1) }
        await #expect(throws: TorrentError.self) { try await disk.read(offset: 199_999, length: 2) }
        try await disk.deleteFiles()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("large").path))
    }

    @Test func separatedSelectionsDoNotStoreUnwantedInteriorPieces() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<24).map(UInt8.init))
        let files = (0..<6).map { TorrentFile(index: $0, path: ["Root", "file-\($0)"], length: 4, offset: Int64($0 * 4)) }
        let disk = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 6, files: files), destination: root, selectedFiles: [1, 5])
        try await disk.prepare()
        try await disk.write(offset: 0, data: Data(bytes[0..<12]))
        try await disk.write(offset: 18, data: Data(bytes[18..<24]))
        #expect(try await disk.verifyPiece(0)); #expect(try await disk.verifyPiece(1)); #expect(try await disk.verifyPiece(3))
        await #expect(throws: TorrentError.self) { try await disk.verifyPiece(2) }
        #expect(try await disk.signatures().first(where: { $0.path.hasSuffix(".parts") })?.size == 10)
        await disk.close()
    }

    @Test func repeatedVirtualPaddingNamesAreAccepted() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 0, 0, 4, 5, 6, 0, 0])
        let files = [TorrentFile(index: 0, path: ["Root", "a"], length: 3, offset: 0), TorrentFile(index: 1, path: ["Root", ".pad", "2"], length: 2, offset: 3, isPadding: true), TorrentFile(index: 2, path: ["Root", "b"], length: 3, offset: 5), TorrentFile(index: 3, path: ["Root", ".pad", "2"], length: 2, offset: 8, isPadding: true)]
        let disk = try TorrentDisk(metainfo: fixture(bytes, pieceLength: 5, files: files), destination: root, selectedFiles: [0, 2])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes)
        #expect(try await disk.verifyPiece(0)); #expect(try await disk.verifyPiece(1))
        await disk.close()
    }

    @Test func failedPreparationRollsBackOnlyNewFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("z-existing")
        let original = Data([9, 9, 9]); try original.write(to: existing)
        let files = [TorrentFile(index: 0, path: ["a-new"], length: 4, offset: 0), TorrentFile(index: 1, path: ["z-existing"], length: 4, offset: 4)]
        let disk = try TorrentDisk(metainfo: fixture(Data(repeating: 1, count: 8), pieceLength: 4, files: files), destination: root, selectedFiles: [0, 1], allowExisting: true)
        await #expect(throws: TorrentError.self) { try await disk.prepare() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a-new").path))
        #expect(try Data(contentsOf: existing) == original)
    }

    @Test func ancestorSymlinkAndReplacedDestinationAreRejected() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        let destination = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Root"), withDestinationURL: outside)
        let bytes = Data([1, 2, 3, 4])
        let meta = fixture(bytes, pieceLength: 4, files: [TorrentFile(index: 0, path: ["Root", "file"], length: 4, offset: 0)])
        let refused = try TorrentDisk(metainfo: meta, destination: destination, selectedFiles: [0])
        await #expect(throws: TorrentError.self) { try await refused.prepare() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Root"))
        let disk = try TorrentDisk(metainfo: meta, destination: destination, selectedFiles: [0])
        try await disk.prepare(); try await disk.write(offset: 0, data: bytes)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("original-destination"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await #expect(throws: TorrentError.self) { try await disk.read(offset: 0, length: 4) }
        await #expect(throws: TorrentError.self) { try await disk.write(offset: 0, data: bytes) }
        await disk.close()
    }

    @Test func rankedFileProgressMatchesByteReferenceAcrossWordBoundaries() async throws {
        var files: [TorrentFile] = [], offset: Int64 = 0
        for index in 0..<257 {
            let length = Int64(index % 31)
            files.append(TorrentFile(index: index, path: ["Root", "f\(index)"], length: length, offset: offset))
            offset += length
        }
        let meta = fixture(Data(count: Int(offset)), pieceLength: 17, files: files)
        let disk = try TorrentDisk(metainfo: meta, destination: URL(fileURLWithPath: "/unused"), selectedFiles: Set(files.map(\.index)))
        var verified = PieceBitset(count: meta.pieceHashes.count)
        for index in 0..<verified.count { verified[index] = index % 3 == 0 || index % 11 == 0 }
        let snapshots = await disk.fileSnapshots(verified: verified)
        for item in snapshots {
            let expected = (item.file.offset..<(item.file.offset + item.file.length)).filter { verified[Int($0 / 17)] }.count
            #expect(item.verifiedBytes == Int64(expected))
        }
    }
}
