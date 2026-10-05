import XCTest
import Foundation
import CryptoKit
import SQLite3
import TorrentCore
@testable import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    private func refreshFixture(_ files: [(String, Data)], pieceLength: Int = 32_768, revision: Int = 0, name: String = "series") throws -> TorrentMetainfo {
        let payload = files.reduce(into: Data()) { $0.append($1.1) }
        let hashes = stride(from: 0, to: payload.count, by: pieceLength).reduce(into: Data()) {
            $0.append(Data(Insecure.SHA1.hash(data: payload.subdata(in: $1..<min($1 + pieceLength, payload.count)))))
        }
        let entries: [BencodeValue] = files.map { .dictionary([
            "path": .list([.bytes(Data($0.0.utf8))]), "length": .integer(Int64($0.1.count))
        ]) }
        return try MetainfoParser.parse(Bencode.encode(.dictionary(["info": .dictionary([
            "name": .bytes(Data(name.utf8)), "piece length": .integer(Int64(pieceLength)),
            "pieces": .bytes(hashes), "files": .list(entries), "private": .integer(1), "revision": .integer(Int64(revision))
        ])])))
    }

    private func refreshPayload(_ data: Data, path: String, root: URL) throws {
        let url = root.appendingPathComponent("series/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testRefreshInsertionPreservesVerifiedBytesSelectionHistoryAndSourceAcrossRelaunch() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data(repeating: 42, count: 65_536), skipped = Data(repeating: 7, count: 32_768)
        let old = try refreshFixture([("first.bin", first), ("skipped.bin", skipped)])
        let fresh = try refreshFixture([("new.bin", Data(repeating: 11, count: 32_768)), ("first.bin", first), ("skipped.bin", skipped)])
        try refreshPayload(first, path: "first.bin", root: root)
        let state = root.appendingPathComponent("state"), engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], seedRatio: 2, allowExisting: true, startPaused: true, downloadedBytes: 65_536, uploadedBytes: 17)
        let source = try TorrentRefreshSource(url: URL(string: "https://example.org/latest.torrent")!)
        try await engine.setRefreshSource(source, for: old.id)
        let refreshed = try await engine.refresh(id: old.id, metainfo: fresh)
        XCTAssertEqual(refreshed, fresh.id)
        let snapshots = await engine.currentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshot.id, fresh.id)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.files.map(\.selected), [true, true, false])
        XCTAssertEqual(snapshot.completedBytes, 65_536)
        XCTAssertEqual(snapshot.downloadedBytes, 65_536)
        XCTAssertEqual(snapshot.uploadedBytes, 17)
        XCTAssertEqual(snapshot.seedRatio, 2)
        XCTAssertEqual(snapshot.refreshSource, source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/first.bin")), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/skipped.bin").path))
        try await engine.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let reloaded = await restored.currentSnapshots()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, fresh.id)
        XCTAssertEqual(reloaded.first?.completedBytes, 65_536)
        XCTAssertEqual(reloaded.first?.refreshSource, source)
        XCTAssertEqual(reloaded.first?.state, .paused)
        try await restored.shutdownForProfileSwitch()
    }

    func testRefreshPiecePlanRequiresMatchingHashesLengthsAndBackingBytes() throws {
        let bytes = Data(repeating: 42, count: 65_536)
        let old = try refreshFixture([("first.bin", bytes)])
        let inserted = try refreshFixture([("new.bin", Data(repeating: 3, count: 32_768)), ("first.bin", bytes)])
        let owned = DiskSignature(path: "series/first.bin", device: 1, inode: 1, size: Int64(bytes.count), modifiedSeconds: 0, modifiedNanoseconds: 0)
        let before = EngineRecord(metainfo: old, destination: URL(fileURLWithPath: "/unused"), ownedSignatures: [owned], selectedFiles: [0], seedRatio: nil, downloaded: 0, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: 2, repeating: true))
        var after = before
        after.metainfo = inserted; after.selectedFiles = [0, 1]
        let plan = TorrentEngine.refreshPiecePlan(old: before, new: after)
        XCTAssertFalse(plan.verified[0])
        XCTAssertTrue(plan.verified[1]); XCTAssertTrue(plan.verified[2])
        XCTAssertTrue(plan.check.isEmpty)
        after.metainfo = try refreshFixture([("first.bin", bytes)], pieceLength: 65_536)
        after.selectedFiles = [0]
        let changedLength = TorrentEngine.refreshPiecePlan(old: before, new: after)
        XCTAssertEqual(changedLength.verified.setCount, 0)
        XCTAssertEqual(changedLength.check, [0])
        after.metainfo = try refreshFixture([("first.bin", Data(repeating: 9, count: 65_536))])
        let changedHash = TorrentEngine.refreshPiecePlan(old: before, new: after)
        XCTAssertEqual(changedHash.verified.setCount, 0)
        XCTAssertEqual(changedHash.check, [0, 1])
        after.metainfo = try refreshFixture([("different.bin", bytes)])
        XCTAssertEqual(TorrentEngine.refreshPiecePlan(old: before, new: after).verified.setCount, 0)
    }

    func testRefreshDoesNotTrustSkippedFileBoundaryOrOldShortTail() throws {
        let first = Data(repeating: 42, count: 20_000), skipped = Data(repeating: 7, count: 12_768)
        let old = try refreshFixture([("first.bin", first), ("skipped.bin", skipped)])
        let owned = DiskSignature(path: "series/first.bin", device: 1, inode: 1, size: 20_000, modifiedSeconds: 0, modifiedNanoseconds: 0)
        let before = EngineRecord(metainfo: old, destination: URL(fileURLWithPath: "/unused"), ownedSignatures: [owned], selectedFiles: [0], seedRatio: nil, downloaded: 0, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: 1, repeating: true))
        var after = before
        after.metainfo = try refreshFixture([("first.bin", first), ("skipped.bin", skipped)], revision: 1)
        let plan = TorrentEngine.refreshPiecePlan(old: before, new: after)
        XCTAssertEqual(plan.verified.setCount, 0)
        XCTAssertTrue(plan.check.isEmpty)
        let short = try refreshFixture([("first.bin", first)])
        var shortBefore = before; shortBefore.metainfo = short
        after.metainfo = try refreshFixture([("first.bin", first), ("new.bin", skipped)])
        after.selectedFiles = [0, 1]
        XCTAssertEqual(TorrentEngine.refreshPiecePlan(old: shortBefore, new: after).verified.setCount, 0)
    }

    func testRefreshFailurePreservesOldTransferAndDoesNotCreateNewFiles() async throws {
        for failure in ["size", "unowned", "missing", "root"] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = Data(repeating: 42, count: 32_768)
            let old = try refreshFixture([("first.bin", payload)])
            try refreshPayload(payload, path: "first.bin", root: root)
            let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
            _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
            var files = [("first.bin", payload), ("a-new.bin", payload)]
            if failure == "size" { files[0].1 = Data(repeating: 1, count: 16_384) }
            if failure == "unowned" { files.append(("z-unowned.bin", payload)); try refreshPayload(payload, path: "z-unowned.bin", root: root) }
            if failure == "missing" { try FileManager.default.removeItem(at: root.appendingPathComponent("series/first.bin")) }
            let fresh = try refreshFixture(files, name: failure == "root" ? "renamed" : "series")
            do { _ = try await engine.refresh(id: old.id, metainfo: fresh); XCTFail("Unsafe refresh must fail: \(failure)") }
            catch { }
            let snapshot = await engine.currentSnapshots()
            XCTAssertEqual(snapshot.count, 1)
            XCTAssertEqual(snapshot.first?.id, old.id)
            XCTAssertEqual(snapshot.first?.state, .paused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/a-new.bin").path))
            if failure != "missing" { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/first.bin")), payload) }
            try await engine.shutdownForProfileSwitch()
        }
    }

    func testRefreshEqualHashAndEmptySelectionDoNotTouchPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("unmounted")
        let old = try refreshFixture([("first.bin", Data(repeating: 42, count: 32_768))])
        let fresh = try refreshFixture([("first.bin", Data(repeating: 42, count: 32_768))], revision: 1)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: destination, selectedFiles: [], startPaused: true)
        let unchanged = try await engine.refresh(id: old.id, metainfo: old)
        XCTAssertEqual(unchanged, old.id)
        let changed = try await engine.refresh(id: old.id, metainfo: fresh)
        XCTAssertEqual(changed, fresh.id)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertEqual(snapshot?.selectedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await engine.shutdownForProfileSwitch()
    }

    func testRefreshRetainsRemovedFileOwnershipForExplicitDeletion() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let old = try refreshFixture([("first.bin", payload), ("retained.bin", payload)])
        let fresh = try refreshFixture([("retained.bin", payload), ("new.bin", payload)])
        try refreshPayload(payload, path: "first.bin", root: root)
        try refreshPayload(payload, path: "retained.bin", root: root)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0, 1], allowExisting: true, startPaused: true, downloadedBytes: 65_536)
        await engine.refreshUploadAccountingForTest(old.id)
        _ = try await engine.refresh(id: old.id, metainfo: fresh)
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.downloadedBytes, 65_536)
        XCTAssertEqual(snapshot?.uploadedBytes, 28)
        XCTAssertEqual(snapshot?.files.map(\.uploadedBytes), [11, 0])
        XCTAssertEqual(snapshot?.fileUploadHistoryComplete, false)
        let saved = try await engine.persistence.load()
        XCTAssertEqual(saved?.records.first?.uploaded, 28)
        XCTAssertEqual(saved?.records.first?.fileUploadedBytes, [0: 11])
        XCTAssertEqual(saved?.records.first?.fileUploadHistoryComplete, false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/first.bin")), payload)
        try await engine.remove(fresh.id, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/first.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/new.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/retained.bin").path))
        try await engine.shutdownForProfileSwitch()
    }

    func testRefreshCancelledWhileWaitingForCommitRollsBackCreatedPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let old = try refreshFixture([("first.bin", payload)])
        let fresh = try refreshFixture([("first.bin", payload), ("new.bin", payload)])
        try refreshPayload(payload, path: "first.bin", root: root)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
        await engine.acquireSaveGate()
        let task = Task { try await engine.refresh(id: old.id, metainfo: fresh) }
        for _ in 0..<200 {
            if await engine.saveGateWaiters.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await engine.releaseSaveGate()
        do { _ = try await task.value; XCTFail("Cancelled refresh must fail") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/new.bin").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/first.bin")), payload)
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first?.id, old.id)
        XCTAssertEqual(snapshots.first?.state, .paused)
        try await engine.shutdownForProfileSwitch()
    }

    func testRefreshDatabaseFailureRollsBackBothIdentityAndCreatedPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let old = try refreshFixture([("first.bin", payload)])
        let fresh = try refreshFixture([("first.bin", payload), ("new.bin", payload)])
        try refreshPayload(payload, path: "first.bin", root: root)
        let state = root.appendingPathComponent("state"), engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.appendingPathComponent("Torrenza.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_refresh BEFORE INSERT ON records WHEN NEW.namespace='metainfo' AND NEW.key='\(fresh.id)' BEGIN SELECT RAISE(ABORT,'refresh fixture failure'); END", nil, nil, nil), SQLITE_OK)
        do { _ = try await engine.refresh(id: old.id, metainfo: fresh); XCTFail("Injected database failure must reject refresh") }
        catch { }
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first?.id, old.id)
        XCTAssertEqual(snapshots.first?.state, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/new.bin").path))
        let saved = try await engine.persistence.load()
        XCTAssertEqual(saved?.records.map { $0.metainfo.id }, [old.id])
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_refresh", nil, nil, nil), SQLITE_OK)
        try await engine.shutdownForProfileSwitch()
    }

    func testRefreshCompletedAutoStartsWhileExplicitPauseAndQuarantineStayStopped() async throws {
        for status: TransferState in [.completed, .paused, .failed] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = Data(repeating: 42, count: 32_768)
            let old = try refreshFixture([("first.bin", payload)])
            let fresh = try refreshFixture([("first.bin", payload), ("new.bin", payload)])
            try refreshPayload(payload, path: "first.bin", root: root)
            let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
            _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
            await engine.refreshAdmissionStateForTest(old.id, state: status)
            _ = try await engine.refresh(id: old.id, metainfo: fresh)
            let saved = try await engine.persistence.load()
            let record = try XCTUnwrap(saved?.records.first)
            XCTAssertEqual(record.wantedRunning, status == .completed)
            XCTAssertEqual(record.quarantineError, status == .failed ? "Saved storage error" : nil)
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.state, status == .completed ? .queued : status)
            try await engine.shutdownForProfileSwitch()
        }
    }

    func testRefreshShutdownWaitsForCandidateCleanupBeforeClosingProfile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let old = try refreshFixture([("first.bin", payload)])
        let fresh = try refreshFixture([("first.bin", payload), ("new.bin", payload)])
        try refreshPayload(payload, path: "first.bin", root: root)
        let state = root.appendingPathComponent("state"), engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
        await engine.acquireSaveGate()
        let refresh = Task { try await engine.refresh(id: old.id, metainfo: fresh) }
        for _ in 0..<200 {
            if await engine.saveGateWaiters.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let shutdown = Task { try await engine.shutdownForProfileSwitch() }
        for _ in 0..<200 {
            if await engine.shuttingDown { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await engine.releaseSaveGate()
        do { _ = try await refresh.value; XCTFail("Profile shutdown must cancel an uncommitted refresh") }
        catch is CancellationError { }
        try await shutdown.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/new.bin").path))
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.id), [old.id])
        XCTAssertEqual(snapshots.first?.state, .paused)
        try await restored.shutdownForProfileSwitch()
    }

    func testRefreshWaitsForAnEarlierPauseOperationAndRejectsAnAlreadyManagedHash() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let old = try refreshFixture([("first.bin", payload)])
        let fresh = try refreshFixture([("first.bin", payload), ("new.bin", payload)])
        try refreshPayload(payload, path: "first.bin", root: root)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
        await engine.acquireSaveGate()
        let pause = Task { await engine.pause(old.id) }
        for _ in 0..<200 {
            if await engine.saveGateWaiters.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        do { _ = try await engine.refresh(id: old.id, metainfo: fresh); XCTFail("Earlier pause must finish before refresh") }
        catch let error as TorrentError { XCTAssertEqual(error, .storage("Wait for this torrent's current operation to finish")) }
        await engine.releaseSaveGate()
        await pause.value
        _ = try await engine.add(metainfo: fresh, destination: root.appendingPathComponent("metadata-only"), selectedFiles: [], startPaused: true)
        do { _ = try await engine.refresh(id: old.id, metainfo: fresh); XCTFail("An already managed new hash must reject refresh") }
        catch let error as TorrentError { XCTAssertEqual(error, .storage("The refreshed torrent is already in your library")) }
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(Set(snapshots.map(\.id)), [old.id, fresh.id])
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .paused })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/new.bin").path))
        try await engine.shutdownForProfileSwitch()
    }

    func testRefreshSelectionLossRequiresExplicitChoiceBeforePreparingReplacement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768), other = Data(repeating: 7, count: 32_768)
        let old = try refreshFixture([("selected.bin", payload), ("skipped.bin", other)])
        let fresh = try refreshFixture([("skipped.bin", other)])
        try refreshPayload(payload, path: "selected.bin", root: root)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: old, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
        for selection: Set<Int>? in [nil, []] {
            do {
                _ = try await engine.refresh(id: old.id, metainfo: fresh, selectedFiles: selection)
                XCTFail("Lost selection must request a choice")
            } catch is TorrentRefreshSelectionRequired { }
            let snapshots = await engine.currentSnapshots()
            XCTAssertEqual(snapshots.map(\.id), [old.id])
            XCTAssertEqual(snapshots.first?.state, .paused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/skipped.bin").path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/selected.bin")), payload)
        }
        do {
            _ = try await engine.refresh(id: old.id, metainfo: fresh, selectedFiles: [99])
            XCTFail("Selection must refer to refreshed file indices")
        } catch let error as TorrentError { XCTAssertEqual(error, .storage("Invalid refreshed file selection")) }
        let newID = try await engine.refresh(id: old.id, metainfo: fresh, selectedFiles: [0])
        XCTAssertEqual(newID, fresh.id)
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first?.files.map(\.selected), [true])
        XCTAssertEqual(snapshots.first?.state, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("series/skipped.bin").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("series/selected.bin")), payload)
        try await engine.shutdownForProfileSwitch()
    }
}

private extension TorrentEngine {
    func refreshUploadAccountingForTest(_ id: String) {
        guard let session = sessions[id] else { return }
        session.recordUploadedBlock(offset: 0, length: 17)
        session.recordUploadedBlock(offset: 32_768, length: 11)
    }

    func refreshAdmissionStateForTest(_ id: String, state: TransferState) {
        guard let session = sessions[id] else { return }
        session.snapshot.state = state
        session.record.wantedRunning = false
        session.record.quarantineError = state == .failed ? "Saved storage error" : nil
        session.snapshot.error = session.record.quarantineError
        // Keep auto-start assertions independent of listener availability.
        configuration.maxDownloads = 0
    }
}
