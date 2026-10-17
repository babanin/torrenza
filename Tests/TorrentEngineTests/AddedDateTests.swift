import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    func testAddedDatePersistsMetadataOnlyImportAndRefreshAcrossRelaunch() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let destination = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = fixture(Data(repeating: 7, count: 32_768))
        let refreshed = fixture(Data(repeating: 9, count: 32_768))
        let engine = TorrentEngine(stateDirectory: state)
        let before = Date()
        _ = try await engine.add(metainfo: original, destination: destination, selectedFiles: [])
        let after = Date()
        let snapshots = await engine.currentSnapshots()
        let addedAt = try XCTUnwrap(snapshots.first?.addedAt)
        XCTAssertGreaterThanOrEqual(addedAt, before)
        XCTAssertLessThanOrEqual(addedAt, after)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

        _ = try await engine.refresh(id: original.id, metainfo: refreshed)
        let refreshedSnapshots = await engine.currentSnapshots()
        XCTAssertEqual(refreshedSnapshots.first?.addedAt, addedAt)
        try await engine.shutdownForProfileSwitch()

        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let restoredSnapshots = await restored.currentSnapshots()
        XCTAssertEqual(restoredSnapshots.first?.id, refreshed.id)
        XCTAssertEqual(restoredSnapshots.first?.addedAt, addedAt)
        XCTAssertEqual(restoredSnapshots.first?.state, .paused)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try await restored.shutdownForProfileSwitch()
    }

    func testAddedDateForExistingPayloadImportUsesThisProfileImportTime() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 7, count: 32_768)
        let metainfo = fixture(payload)
        try payload.write(to: root.appendingPathComponent(metainfo.name))
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        let before = Date()
        _ = try await engine.add(metainfo: metainfo, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true, downloadedBytes: 65_536, uploadedBytes: 16_384, savedVerifiedPieces: PieceBitset(count: 1, repeating: true))
        let after = Date()
        let snapshots = await engine.currentSnapshots()
        let addedAt = try XCTUnwrap(snapshots.first?.addedAt)
        XCTAssertGreaterThanOrEqual(addedAt, before)
        XCTAssertLessThanOrEqual(addedAt, after)
        XCTAssertEqual(snapshots.first?.completedBytes, 32_768)
        XCTAssertEqual(snapshots.first?.state, .paused)
        try await engine.shutdownForProfileSwitch()
    }

    func testAddedDateIsNotInventedForLegacyRecords() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let metainfo = fixture(Data(repeating: 7, count: 32_768))
        let record = EngineRecord(metainfo: metainfo, destination: root, selectedFiles: [], seedRatio: 1, downloaded: 0, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: 1))
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["addedAt"])
        XCTAssertNil(try JSONDecoder().decode(EngineRecord.self, from: data).addedAt)

        let persistence = EnginePersistence(directory: root.appendingPathComponent("state"))
        try await persistence.save(EngineArchive(settings: EngineSettings(), records: [record]))
        try await persistence.close()
        let restored = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots.first?.addedAt)
        _ = try await restored.refresh(id: metainfo.id, metainfo: fixture(Data(repeating: 9, count: 32_768)))
        let refreshedSnapshots = await restored.currentSnapshots()
        XCTAssertNil(refreshedSnapshots.first?.addedAt)
        try await restored.shutdownForProfileSwitch()
    }

    func testAddedDateAfterFailedAddBelongsToSuccessfulRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let metainfo = fixture(Data(repeating: 7, count: 32_768))
        let blockedDestination = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedDestination)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: metainfo, destination: blockedDestination, selectedFiles: [0], startPaused: true)
            XCTFail("A regular file cannot be a download destination")
        } catch { }
        let failedSnapshots = await engine.currentSnapshots()
        XCTAssertTrue(failedSnapshots.isEmpty)
        let beforeRetry = Date()
        _ = try await engine.add(metainfo: metainfo, destination: root, selectedFiles: [0], startPaused: true)
        let afterRetry = Date()
        let snapshots = await engine.currentSnapshots()
        let addedAt = try XCTUnwrap(snapshots.first?.addedAt)
        XCTAssertGreaterThanOrEqual(addedAt, beforeRetry)
        XCTAssertLessThanOrEqual(addedAt, afterRetry)
        try await engine.shutdownForProfileSwitch()
    }
}
