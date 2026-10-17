import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    func testIncrementalSelectionStartsMetadataOnlyAndRetainsDisabledPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = incrementalSelectionFixture()
        let state = root.appendingPathComponent("state")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = TorrentEngine(stateDirectory: state)
        _ = try await engine.add(metainfo: meta, destination: destination, selectedFiles: [], seedRatio: nil)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try await engine.setFilesSelected(meta.id, indices: [1], selected: true)
        _ = try await waitFor(engine, id: meta.id, state: .downloading)
        let first = destination.appendingPathComponent("bundle/first.bin")
        let second = destination.appendingPathComponent("bundle/second.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        try await engine.setFilesSelected(meta.id, indices: [0], selected: true)
        var snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.files.map(\.selected), [true, true])
        XCTAssertEqual(snapshot?.state, .downloading)
        try await engine.setFilesSelected(meta.id, indices: [1], selected: false)
        snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.files.map(\.selected), [true, false])
        XCTAssertEqual(snapshot?.state, .downloading)
        try await engine.setFilesSelected(meta.id, indices: [0], selected: false)
        snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        try await engine.setFilesSelected(meta.id, indices: [1], selected: true)
        await engine.pause(meta.id)
        // Selecting an already enabled file must also resume a paused torrent.
        try await engine.setFilesSelected(meta.id, indices: [1], selected: true)
        _ = try await waitFor(engine, id: meta.id, state: .downloading)
        try await engine.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        snapshot = await restored.currentSnapshots().first
        XCTAssertEqual(snapshot?.files.map(\.selected), [false, true])
        _ = try await waitFor(restored, id: meta.id, state: .downloading)
        try await restored.shutdownForProfileSwitch()
    }

    func testQueuedSelectionDeltasAndPauseUseAuthoritativeOrder() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = incrementalSelectionFixture()
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [], seedRatio: nil)
        // Hold the production action gate to deterministically enqueue overlapping
        // changes without relying on timing of filesystem or network operations.
        await engine.acquireActionGate(meta.id)
        let first = Task { try await engine.setFilesSelected(meta.id, indices: [0], selected: true) }
        try await waitForActionCount(engine, id: meta.id, count: 1)
        let second = Task { try await engine.setFilesSelected(meta.id, indices: [1], selected: true) }
        try await waitForActionCount(engine, id: meta.id, count: 2)
        let third = Task { try await engine.setFilesSelected(meta.id, indices: [0], selected: false) }
        try await waitForActionCount(engine, id: meta.id, count: 3)
        let pause = Task { await engine.pause(meta.id) }
        try await waitForActionCount(engine, id: meta.id, count: 4)
        await engine.recheck(meta.id) // Conflicting operations must not disrupt the queue.
        do { try await engine.remove(meta.id); XCTFail("Remove must wait for file changes") } catch { }
        await engine.releaseActionGate(meta.id)
        try await first.value
        try await second.value
        try await third.value
        await pause.value
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.files.map(\.selected), [false, true])
        XCTAssertEqual(snapshot?.state, .paused)
        let archived = try await engine.persistence.load()
        XCTAssertEqual(archived?.records.first?.selectedFiles, [1])
        XCTAssertEqual(archived?.records.first?.wantedRunning, false)
        try await engine.shutdownForProfileSwitch()
    }

    func testIncrementalSelectionPreservesQuarantineAndDoesNotCreateNewPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = incrementalSelectionFixture()
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
        try await engine.shutdownForProfileSwitch()
        let first = root.appendingPathComponent("bundle/first.bin")
        let second = root.appendingPathComponent("bundle/second.bin")
        try FileManager.default.removeItem(at: first)
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        do { try await restored.setFilesSelected(meta.id, indices: [1], selected: true); XCTFail("Missing owned payload must fail") } catch { }
        let failed = await restored.currentSnapshots().first
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertNotNil(failed?.error)
        do { try await restored.setFilesSelected(meta.id, indices: [0], selected: true); XCTFail("File enabling must not clear quarantine") } catch { }
        let retried = await restored.currentSnapshots().first
        XCTAssertEqual(retried?.error, failed?.error)
        XCTAssertEqual(retried?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        try await restored.shutdownForProfileSwitch()
    }

    func testSelectionQueuesAreIndependentAcrossTorrents() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = incrementalSelectionFixture()
        let other = fixture(Data(repeating: 17, count: 32_768), name: "other.bin")
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: first, destination: root, selectedFiles: [], seedRatio: nil)
        _ = try await engine.add(metainfo: other, destination: root, selectedFiles: [], seedRatio: nil)
        await engine.acquireActionGate(first.id)
        let blocked = Task { try await engine.setFilesSelected(first.id, indices: [0], selected: true) }
        try await waitForActionCount(engine, id: first.id, count: 1)
        try await engine.setFilesSelected(other.id, indices: [0], selected: true)
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first { $0.id == other.id }?.state, .downloading)
        XCTAssertEqual(snapshots.first { $0.id == first.id }?.files.map(\.selected), [false, false])
        await engine.releaseActionGate(first.id)
        try await blocked.value
        try await engine.shutdownForProfileSwitch()
    }

    func testProfileShutdownDrainsPendingSelectionActions() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = incrementalSelectionFixture()
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [])
        await engine.acquireActionGate(meta.id)
        let pending = Task { try await engine.setFilesSelected(meta.id, indices: [0], selected: true) }
        try await waitForActionCount(engine, id: meta.id, count: 1)
        let shutdown = Task { try await engine.shutdownForProfileSwitch() }
        for _ in 0..<1_000 {
            if await engine.shuttingDown { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let shuttingDown = await engine.shuttingDown
        XCTAssertTrue(shuttingDown)
        await engine.releaseActionGate(meta.id)
        do { try await pending.value; XCTFail("Queued work must cancel when its profile shuts down") }
        catch is CancellationError { }
        try await shutdown.value
        let pendingCount = await engine.sessionOperationCounts.count
        XCTAssertEqual(pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle").path))
    }

    private func incrementalSelectionFixture() -> TorrentMetainfo {
        let base = fixture(Data(repeating: 42, count: 65_536), name: "bundle")
        return TorrentMetainfo(infoHash: base.infoHash, rawInfo: base.rawInfo, name: base.name, pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [
            TorrentFile(index: 0, path: ["bundle", "first.bin"], length: 32_768, offset: 0),
            TorrentFile(index: 1, path: ["bundle", "second.bin"], length: 32_768, offset: 32_768)
        ], trackerTiers: [], isPrivate: true, isMultiFile: true)
    }

    private func waitForActionCount(_ engine: TorrentEngine, id: String, count: Int) async throws {
        for _ in 0..<1_000 {
            if await engine.sessionOperationCounts[id] == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Action did not enter the per-torrent queue")
        throw TorrentError.storage("Timed out waiting for queued action")
    }
}
