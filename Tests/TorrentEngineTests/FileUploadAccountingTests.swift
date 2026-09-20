import XCTest
import Foundation
import TorrentCore
@testable import TorrentEngine

final class FileUploadAccountingTests: XCTestCase, @unchecked Sendable {
    private func record(lengths: [Int64] = [10, 0, 20], padding: Set<Int> = [], uploaded: Int64 = 0) -> EngineRecord {
        var offset: Int64 = 0
        let files = lengths.enumerated().map { index, length in
            defer { offset += length }
            return TorrentFile(index: index, path: ["fixture", "file-\(index)"], length: length, offset: offset, isPadding: padding.contains(index))
        }
        let meta = TorrentMetainfo(infoHash: Data(repeating: 5, count: 20), rawInfo: Data("de".utf8), name: "fixture", pieceLength: 32_768, pieceHashes: [Data(repeating: 6, count: 20)], files: files, trackerTiers: [], isPrivate: true, isMultiFile: files.count > 1)
        return EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/unused-upload-fixture"), selectedFiles: Set(files.filter { !$0.isPadding }.map(\.index)), seedRatio: nil, downloaded: 0, uploaded: uploaded, wantedRunning: false, verified: PieceBitset(count: 1, repeating: true))
    }

    func testCrossFileRepeatedUploadsCountPayloadAndSkipEmptyFiles() {
        let session = EngineSession(record: record())
        session.recordUploadedBlock(offset: 5, length: 15)
        session.recordUploadedBlock(offset: 5, length: 15)
        XCTAssertEqual(session.snapshot.files.map(\.uploadedBytes), [10, 0, 20])
        XCTAssertEqual(session.record.fileUploadedBytes, [0: 10, 2: 20])
        XCTAssertEqual(session.snapshot.uploadedBytes, 30)
        XCTAssertTrue(session.snapshot.fileUploadHistoryComplete)
        XCTAssertTrue(session.record.hasValidFileUploadHistory)
    }

    func testPaddingHasNoVisibleCounterAndDoesNotMakeHistoryIncomplete() {
        let session = EngineSession(record: record(lengths: [10, 5, 15], padding: [1]))
        session.recordUploadedBlock(offset: 5, length: 15)
        XCTAssertEqual(session.snapshot.files.map(\.uploadedBytes), [5, 5])
        XCTAssertEqual(session.record.fileUploadedBytes, [0: 5, 2: 5])
        XCTAssertEqual(session.snapshot.uploadedBytes, 15)
        XCTAssertTrue(session.snapshot.fileUploadHistoryComplete)
        XCTAssertTrue(session.record.hasValidFileUploadHistory)
    }

    func testLegacyAndImportedHistoryIsOnlyAttributedWhenUnambiguous() throws {
        for (lengths, padding, uploaded, complete, expected): ([Int64], Set<Int>, Int64, Bool, [Int64]) in [
            ([10, 20], [], 0, true, [0, 0]),
            ([10, 20], [], 99, false, [0, 0]),
            ([30], [], 99, true, [99]),
            ([25, 5], [1], 99, false, [0])
        ] {
            let original = record(lengths: lengths, padding: padding, uploaded: uploaded)
            let data = try JSONEncoder().encode(original)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["fileUploadedBytes"])
            XCTAssertNil(object["fileUploadHistoryComplete"])
            let legacy = try JSONDecoder().decode(EngineRecord.self, from: data)
            let session = EngineSession(record: legacy)
            XCTAssertEqual(session.snapshot.files.map(\.uploadedBytes), expected)
            XCTAssertEqual(session.snapshot.fileUploadHistoryComplete, complete)
            XCTAssertTrue(session.record.hasValidFileUploadHistory)
        }
    }

    func testCountersAndIncompleteHistorySurviveDatabaseReloadAndProgressRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-file-uploads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EngineSession(record: record(uploaded: 99))
        session.recordUploadedBlock(offset: 5, length: 15)
        let persistence = EnginePersistence(directory: root)
        try await persistence.save(EngineArchive(settings: EngineSettings(), records: [session.record]))
        try await persistence.close()
        let reader = EnginePersistence(directory: root)
        let loaded = try await reader.load()
        let restoredRecord = try XCTUnwrap(loaded?.records.first)
        XCTAssertEqual(restoredRecord.fileUploadedBytes, [0: 5, 2: 10])
        XCTAssertEqual(restoredRecord.fileUploadHistoryComplete, false)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("refresh-state"))
        let restored = await engine.refreshedUploadSnapshot(restoredRecord)
        XCTAssertEqual(restored.files.map(\.uploadedBytes), [5, 0, 10])
        XCTAssertEqual(restored.files.map(\.verifiedBytes), [10, 0, 20])
        XCTAssertEqual(restored.uploadedBytes, 114)
        XCTAssertFalse(restored.fileUploadHistoryComplete)
        await engine.shutdown()
        try await reader.close()
    }

    func testLegacyDatabaseRecordsLoadWithoutNewFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-legacy-uploads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = EnginePersistence(directory: root)
        try await persistence.save(EngineArchive(settings: EngineSettings(), records: [record(uploaded: 99)]))
        try await persistence.close()
        let reader = EnginePersistence(directory: root)
        let loaded = try await reader.load()
        let restored = EngineSession(record: try XCTUnwrap(loaded?.records.first))
        XCTAssertFalse(restored.snapshot.fileUploadHistoryComplete)
        XCTAssertEqual(restored.snapshot.uploadedBytes, 99)
        XCTAssertEqual(restored.snapshot.files.map(\.uploadedBytes), [0, 0, 0])
        try await reader.close()
    }

    func testInvalidSavedAttributionIsRejected() {
        var invalid = record(uploaded: 20)
        invalid.fileUploadHistoryComplete = true
        for counters: [Int: Int64] in [[0: -1], [99: 1], [0: 21], [0: Int64.max, 2: Int64.max]] {
            invalid.fileUploadedBytes = counters
            XCTAssertFalse(invalid.hasValidFileUploadHistory)
        }
        invalid.fileUploadedBytes = [0: 10, 2: 10]
        XCTAssertTrue(invalid.hasValidFileUploadHistory)
    }
}

private extension TorrentEngine {
    func refreshedUploadSnapshot(_ record: EngineRecord) async -> TransferSnapshot {
        let session = EngineSession(record: record)
        await refreshProgress(session)
        return session.snapshot
    }
}
