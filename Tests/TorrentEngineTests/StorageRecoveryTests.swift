import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    private func storageRecoveryRecord(
        root: URL, name: String, resume: Bool? = nil
    ) async throws -> EngineRecord {
        let bytes = Data(repeating: 42, count: 65_536)
        let meta = fixture(bytes, name: name)
        try bytes.write(to: root.appendingPathComponent(name))
        let signature = try await TorrentDisk.currentSignature(destination: root, path: [name])
        var record = EngineRecord(
            metainfo: meta, destination: root, selectedFiles: [0], seedRatio: 0,
            downloaded: Int64(bytes.count), uploaded: 19, wantedRunning: false,
            quarantineError: "Destination volume is unavailable",
            verified: PieceBitset(count: meta.pieceHashes.count, repeating: true)
        )
        record.volumeUUID = try XCTUnwrap(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        record.ownedSignatures = [try XCTUnwrap(signature)]
        record.recoveryWantedRunning = resume
        return record
    }

    private func storageRecoveryEngine(root: URL, records: [EngineRecord]) async throws -> TorrentEngine {
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        try await engine.persistence.save(EngineArchive(cleanShutdown: false, settings: EngineSettings(), records: records))
        try await engine.prepareForActivation()
        try await engine.activatePreparedProfile()
        return engine
    }

    func testDownloadRetriesOnlyRequestedQuarantinedTorrentWithoutHashing() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try await storageRecoveryRecord(root: root, name: "retry.bin", resume: false)
        record.seedRatio = nil
        record.verified[1] = false
        record.downloaded = 32_768
        let other = try await storageRecoveryRecord(root: root, name: "other.bin")
        // Changed bytes with the same identity/size prove retry trusts saved
        // pieces rather than silently performing a Recheck.
        let file = root.appendingPathComponent("retry.bin")
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0, count: 65_536))
        try handle.close()
        let engine = try await storageRecoveryEngine(root: root, records: [record, other])
        try await engine.setFilesSelected(record.metainfo.id, indices: [0], selected: true)
        let snapshots = await engine.currentSnapshots()
        let retried = try XCTUnwrap(snapshots.first { $0.id == record.metainfo.id })
        XCTAssertNil(retried.error)
        XCTAssertEqual(retried.state, .downloading)
        XCTAssertEqual(retried.completedBytes, 32_768)
        XCTAssertEqual(snapshots.first { $0.id == other.metainfo.id }?.state, .failed)
        await engine.pause(record.metainfo.id)
        try await engine.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let afterRestore = await restored.currentSnapshots().first { $0.id == record.metainfo.id }
        XCTAssertNil(afterRestore?.error)
        XCTAssertEqual(afterRestore?.state, .paused)
        XCTAssertEqual(afterRestore?.completedBytes, 32_768)
        await restored.shutdown()
    }

    func testDownloadRetryRetainsSeedRatioLimit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await storageRecoveryRecord(root: root, name: "complete.bin", resume: false)
        let engine = try await storageRecoveryEngine(root: root, records: [record])
        try await engine.setFilesSelected(record.metainfo.id, indices: [0], selected: true)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertNil(snapshot?.error)
        XCTAssertEqual(snapshot?.state, .completed)
        await engine.shutdown()
    }

    func testStorageRecoveryFirstSuccessChecksAllRemainingFailures() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await storageRecoveryRecord(root: root, name: "first.bin")
        let missing = try await storageRecoveryRecord(root: root, name: "missing.bin")
        let last = try await storageRecoveryRecord(root: root, name: "last.bin", resume: false)
        try FileManager.default.removeItem(at: root.appendingPathComponent(missing.metainfo.name))
        let engine = try await storageRecoveryEngine(root: root, records: [first, missing, last])
        await engine.recoverFailedStorage(candidateIDs: [first.metainfo.id, missing.metainfo.id, last.metainfo.id])
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first { $0.id == first.metainfo.id }?.state, .completed)
        XCTAssertEqual(snapshots.first { $0.id == last.metainfo.id }?.state, .paused)
        XCTAssertNil(snapshots.first { $0.id == last.metainfo.id }?.error)
        XCTAssertEqual(snapshots.first { $0.id == missing.metainfo.id }?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(missing.metainfo.name).path))
        await engine.shutdown()
    }

    func testStorageRecoveryFailedSampleDoesNotSweepHealthyFailures() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try await storageRecoveryRecord(root: root, name: "missing.bin")
        let healthy = try await storageRecoveryRecord(root: root, name: "healthy.bin")
        try FileManager.default.removeItem(at: root.appendingPathComponent(missing.metainfo.name))
        let engine = try await storageRecoveryEngine(root: root, records: [missing, healthy])
        await engine.recoverFailedStorage(candidateIDs: [missing.metainfo.id, healthy.metainfo.id])
        let snapshots = await engine.currentSnapshots()
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .failed })
        XCTAssertEqual(snapshots.first { $0.id == healthy.metainfo.id }?.error, healthy.quarantineError)
        await engine.shutdown()
    }

    func testStorageRecoveryRejectsMissingReplacedTruncatedSymlinkAndWrongVolume() async throws {
        for failure in ["missing", "replaced", "truncated", "symlink", "volume"] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            var record = try await storageRecoveryRecord(root: root, name: "payload.bin")
            let file = root.appendingPathComponent(record.metainfo.name)
            switch failure {
            case "missing":
                try FileManager.default.removeItem(at: file)
            case "replaced":
                // Keep the original inode allocated so the replacement cannot reuse it.
                try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.bin"))
                try Data(repeating: 7, count: 65_536).write(to: file)
            case "truncated":
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 1)
                try handle.close()
            case "symlink":
                let original = root.appendingPathComponent("original.bin")
                try FileManager.default.moveItem(at: file, to: original)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
            default:
                record.volumeUUID = "not-the-original-volume"
            }
            let before = try? Data(contentsOf: file)
            let engine = try await storageRecoveryEngine(root: root, records: [record])
            let recovered = await engine.recoverStorage(record.metainfo.id)
            XCTAssertFalse(recovered, failure)
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.state, .failed, failure)
            XCTAssertEqual(snapshot?.error, record.quarantineError, failure)
            XCTAssertEqual(snapshot?.completedBytes, 65_536, failure)
            XCTAssertEqual(try? Data(contentsOf: file), before, failure)
            if failure == "missing" { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            do {
                try await engine.setFilesSelected(record.metainfo.id, indices: [0], selected: true)
                XCTFail("Manual Download must reject unsafe storage: \(failure)")
            } catch {
                XCTAssertNotEqual(error.localizedDescription, record.quarantineError,
                                  "Retry should report the current validation failure")
            }
            let retried = await engine.currentSnapshots().first
            XCTAssertEqual(retried?.state, .failed, failure)
            XCTAssertEqual(retried?.completedBytes, 65_536, failure)
            XCTAssertEqual(try? Data(contentsOf: file), before, failure)
            if failure == "missing" { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            await engine.shutdown()
        }
    }

    func testStorageRecoveryPreservesSavedProgressWithoutHashingAndPersistsPause() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try await storageRecoveryRecord(root: root, name: "payload.bin")
        record.verified[1] = false
        record.downloaded = 32_768
        // Change content in place while retaining identity and length. Recovery
        // must trust saved progress, not turn into an implicit payload Recheck.
        let file = root.appendingPathComponent(record.metainfo.name)
        let handle = try FileHandle(forWritingTo: file)
        let changed = Data(repeating: 0, count: 65_536)
        try handle.write(contentsOf: changed)
        try handle.close()
        let engine = try await storageRecoveryEngine(root: root, records: [record])
        await engine.pause(record.metainfo.id)
        let recovered = await engine.recoverStorage(record.metainfo.id)
        XCTAssertTrue(recovered)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertNil(snapshot?.error)
        XCTAssertEqual(snapshot?.completedBytes, 32_768)
        XCTAssertEqual(snapshot?.downloadedBytes, 32_768)
        XCTAssertEqual(snapshot?.uploadedBytes, 19)
        XCTAssertEqual(try Data(contentsOf: file), changed)
        try await engine.shutdownForProfileSwitch()

        let restored = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let persisted = await restored.currentSnapshots().first
        XCTAssertEqual(persisted?.state, .paused)
        XCTAssertNil(persisted?.error)
        XCTAssertEqual(persisted?.completedBytes, 32_768)
        XCTAssertEqual(persisted?.downloadedBytes, 32_768)
        XCTAssertEqual(persisted?.uploadedBytes, 19)
        await restored.shutdown()
    }

    func testStorageRecoveryRemountRebasesDeviceWithoutChangingOwnership() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try await storageRecoveryRecord(root: root, name: "payload.bin", resume: false)
        let signature = try XCTUnwrap(record.ownedSignatures?.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(signature)) as? [String: Any])
        object["device"] = signature.device ^ 0x0100_0000
        record.ownedSignatures = [try JSONDecoder().decode(DiskSignature.self, from: JSONSerialization.data(withJSONObject: object))]
        let engine = try await storageRecoveryEngine(root: root, records: [record])
        let recovered = await engine.recoverStorage(record.metainfo.id)
        XCTAssertTrue(recovered)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertNil(snapshot?.error)
        await engine.shutdown()
    }

    func testStorageRecoverySuspensionAndShutdownStopBackgroundChecks() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await storageRecoveryRecord(root: root, name: "payload.bin", resume: false)
        let engine = try await storageRecoveryEngine(root: root, records: [record])
        // Failed records have wantedRunning=false: suspension still has to work
        // even though the existing suspended-transfer set is empty.
        await engine.updateActivity()
        let initiallyScheduled = await engine.storageRecoveryTask != nil
        XCTAssertTrue(initiallyScheduled)
        await engine.suspend()
        let suspended = await engine.storageRecoverySuspended
        let scheduledWhileSuspended = await engine.storageRecoveryTask != nil
        XCTAssertTrue(suspended)
        XCTAssertFalse(scheduledWhileSuspended)
        await engine.recoverFailedStorage(candidateIDs: [record.metainfo.id])
        let stillFailed = await engine.currentSnapshots().first
        XCTAssertEqual(stillFailed?.state, .failed)
        await engine.resume()
        let scheduledAfterResume = await engine.storageRecoveryTask != nil
        XCTAssertTrue(scheduledAfterResume)
        await engine.shutdown()
        let scheduledAfterShutdown = await engine.storageRecoveryTask != nil
        XCTAssertFalse(scheduledAfterShutdown)
        let recoveredAfterShutdown = await engine.recoverStorage(record.metainfo.id)
        XCTAssertFalse(recoveredAfterShutdown)
    }

    func testStorageRecoveryDoesNotTouchUnfailedPausedTorrent() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = try await storageRecoveryRecord(root: root, name: "failed.bin", resume: false)
        var paused = try await storageRecoveryRecord(root: root, name: "paused.bin")
        paused.quarantineError = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent(paused.metainfo.name))
        let engine = try await storageRecoveryEngine(root: root, records: [failed, paused])
        await engine.recoverFailedStorage(candidateIDs: [failed.metainfo.id, paused.metainfo.id])
        let snapshots = await engine.currentSnapshots()
        let untouched = snapshots.first { $0.id == paused.metainfo.id }
        XCTAssertEqual(untouched?.state, .paused)
        XCTAssertNil(untouched?.error)
        XCTAssertEqual(untouched?.completedBytes, 65_536)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(paused.metainfo.name).path))
        await engine.updateActivity()
        let scheduled = await engine.storageRecoveryTask != nil
        XCTAssertFalse(scheduled)
        await engine.shutdown()
    }

    func testStorageRecoveryRequiresExistingSelectionBoundarySidecar() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let base = fixture(payload, name: "bundle")
        let meta = TorrentMetainfo(
            infoHash: base.infoHash, rawInfo: base.rawInfo, name: base.name,
            pieceLength: base.pieceLength, pieceHashes: base.pieceHashes,
            files: [
                TorrentFile(index: 0, path: ["selected.bin"], length: 16_384, offset: 0),
                TorrentFile(index: 1, path: ["unselected.bin"], length: 16_384, offset: 16_384)
            ], trackerTiers: [], isPrivate: true, isMultiFile: true
        )
        let disk = try TorrentDisk(metainfo: meta, destination: root, selectedFiles: [0])
        try await disk.prepare()
        let signatures = try await disk.signatures()
        await disk.close()
        let sidecar = try XCTUnwrap(signatures.first { $0.path.hasPrefix(".torrenza-") })
        let sidecarURL = root.appendingPathComponent(sidecar.path)
        try FileManager.default.removeItem(at: sidecarURL)
        var record = EngineRecord(
            metainfo: meta, destination: root, selectedFiles: [0], seedRatio: 0,
            downloaded: 0, uploaded: 0, wantedRunning: false,
            quarantineError: "Destination volume is unavailable",
            verified: PieceBitset(count: meta.pieceHashes.count)
        )
        record.ownedSignatures = signatures
        record.recoveryWantedRunning = false
        let engine = try await storageRecoveryEngine(root: root, records: [record])
        let recovered = await engine.recoverStorage(meta.id)
        XCTAssertFalse(recovered)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unselected.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("selected.bin").path))
        await engine.shutdown()
    }

    func testStorageQuarantinePersistsOriginalRunIntentAcrossRepeatedFailures() async throws {
        for wantedRunning in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            var record = try await storageRecoveryRecord(root: root, name: "payload.bin")
            record.quarantineError = nil
            record.wantedRunning = wantedRunning
            let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
            try await engine.installStorageRecoveryTestRecord(record)
            await engine.quarantine(record.metainfo.id, error: TorrentError.storage("Storage disappeared"))
            await engine.quarantine(record.metainfo.id, error: TorrentError.storage("Still missing"))
            let saved = try await engine.persistence.load()
            XCTAssertEqual(saved?.records.first?.wantedRunning, false)
            XCTAssertEqual(saved?.records.first?.recoveryWantedRunning, wantedRunning)
            XCTAssertEqual(saved?.records.first?.quarantineError, "Storage disappeared")
            let recovered = await engine.recoverStorage(record.metainfo.id)
            XCTAssertTrue(recovered)
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.state, wantedRunning ? .completed : .paused)
            await engine.shutdown()
        }
    }
}

private extension TorrentEngine {
    func installStorageRecoveryTestRecord(_ record: EngineRecord) async throws {
        try await persistence.save(EngineArchive(cleanShutdown: false, settings: EngineSettings(), records: [record]))
        let session = EngineSession(record: record)
        sessions[record.metainfo.id] = session
        await refreshProgress(session)
    }
}
