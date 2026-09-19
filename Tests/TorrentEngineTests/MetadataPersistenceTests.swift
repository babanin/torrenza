import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

final class MetadataPersistenceTests: XCTestCase, @unchecked Sendable {
    func testIncrementalMetadataLoadPreservesRecordsAndRemovesOrphans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let records = (1...3).map { index in
            let meta = TorrentMetainfo(infoHash: Data(repeating: UInt8(index), count: 20), rawInfo: Data("de".utf8), name: "fixture-\(index)", pieceLength: 16_384, pieceHashes: [Data(repeating: UInt8(index), count: 20)], files: [TorrentFile(index: 0, path: ["fixture-\(index)"], length: 16_384, offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
            return EngineRecord(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: 1, downloaded: Int64(index), uploaded: 0, wantedRunning: index == 1, verified: PieceBitset(count: 1, repeating: index == 2))
        }
        let original = EnginePersistence(directory: root)
        try await original.save(EngineArchive(settings: EngineSettings(), records: records))
        try await original.close()
        let store = SQLiteStore(url: root.appendingPathComponent("Torrenza.sqlite"))
        try await store.write([SQLiteEntry(namespace: "metainfo", key: "orphan", value: Data("unused".utf8))])
        let reader = EnginePersistence(directory: root)
        let loaded = try await reader.load()
        let archive = try XCTUnwrap(loaded)
        XCTAssertEqual(archive.records.count, records.count)
        for expected in records {
            let actual = try XCTUnwrap(archive.records.first { $0.metainfo.id == expected.metainfo.id })
            XCTAssertEqual(actual.metainfo, expected.metainfo)
            XCTAssertEqual(actual.verified, expected.verified)
            XCTAssertEqual(actual.wantedRunning, expected.wantedRunning)
            XCTAssertEqual(actual.downloaded, expected.downloaded)
        }
        try await reader.save(archive)
        let keys = try await store.keys(namespace: "metainfo")
        XCTAssertEqual(Set(keys), Set(records.map { $0.metainfo.id }))
        try await reader.close()
        try await store.close()
    }

    func testIncrementalMetadataLoadRejectsMissingOrMismatchedIdentity() async throws {
        for mismatch in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-metadata-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let meta = TorrentMetainfo(infoHash: Data(repeating: 1, count: 20), rawInfo: Data(), name: "fixture", pieceLength: 16_384, pieceHashes: [], files: [], trackerTiers: [], isPrivate: true, isMultiFile: false)
            let record = EngineRecord(metainfo: meta, destination: root, selectedFiles: [], seedRatio: 1, downloaded: 0, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: 0))
            let original = EnginePersistence(directory: root)
            try await original.save(EngineArchive(settings: EngineSettings(), records: [record]))
            try await original.close()
            let store = SQLiteStore(url: root.appendingPathComponent("Torrenza.sqlite"))
            let other = TorrentMetainfo(infoHash: Data(repeating: 2, count: 20), rawInfo: Data(), name: "other", pieceLength: 16_384, pieceHashes: [], files: [], trackerTiers: [], isPrivate: true, isMultiFile: false)
            try await store.write([SQLiteEntry(namespace: "metainfo", key: meta.id, value: mismatch ? try JSONEncoder().encode(other) : nil)])
            let reader = EnginePersistence(directory: root)
            do {
                _ = try await reader.load()
                XCTFail("Damaged saved metadata must fail to load")
            } catch let error as TorrentError {
                XCTAssertEqual(error, .storage(mismatch ? "Saved torrent identity does not match" : "Saved torrent metadata is missing"))
            }
            try await reader.close()
            try await store.close()
        }
    }
}
