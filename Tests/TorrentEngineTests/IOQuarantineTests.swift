import XCTest
import Foundation
import Network
import TorrentCore
import TorrentWire
@testable import TorrentEngine

extension EngineTests {
    func testFailedPeerSendDoesNotCountUploadedFileBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let meta = fixture(payload)
        try payload.write(to: root.appendingPathComponent(meta.name))
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, allowExisting: true, startPaused: true)
            do {
                try await engine.exerciseFailedPeerUpload(meta.id)
                XCTFail("Sending to a closed peer must fail")
            } catch { }
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.uploadedBytes, 0)
            XCTAssertEqual(snapshot?.files.first?.uploadedBytes, 0)
            XCTAssertNil(snapshot?.error)
            let statistics = await engine.statistics()
            XCTAssertEqual(statistics.current.uploadedBytes, 0)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }
    }

    func testUploadShortReadQuarantinesOnlyAffectedTorrentAndPersistsError() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let meta = fixture(payload)
        let other = fixture(payload, name: "other.bin")
        let file = root.appendingPathComponent(meta.name)
        try payload.write(to: file)
        try payload.write(to: root.appendingPathComponent(other.name))
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, allowExisting: true, startPaused: true)
        _ = try await engine.add(metainfo: other, destination: root, selectedFiles: [0], seedRatio: nil, allowExisting: true, startPaused: true)
        // Retain the inode so the actual short-read path is exercised.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        do { try await engine.exerciseQuarantineUpload(meta.id); XCTFail("Short reads must fail") }
        catch TorrentError.storage { }
        let snapshots = await engine.currentSnapshots()
        let failed = try XCTUnwrap(snapshots.first { $0.id == meta.id })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.contains("truncated") == true)
        XCTAssertEqual(failed.swarm.connectedPeers, 0)
        XCTAssertEqual(failed.uploadedBytes, 0)
        XCTAssertEqual(failed.files.first?.uploadedBytes, 0)
        XCTAssertEqual(snapshots.first { $0.id == other.id }?.state, .paused)
        await engine.volumesChanged()
        await engine.tick()
        let afterTick = await engine.currentSnapshots().first { $0.id == meta.id }
        XCTAssertEqual(afterTick?.state, .failed)
        XCTAssertEqual(afterTick?.error, failed.error)
        // Read the committed record before shutdown to prove immediate persistence.
        let archive = try await EnginePersistence(directory: state).load()
        XCTAssertEqual(archive?.records.first { $0.metainfo.id == meta.id }?.quarantineError, failed.error)
        XCTAssertEqual(archive?.records.first { $0.metainfo.id == meta.id }?.wantedRunning, false)
        await engine.shutdown()
        let restored = TorrentEngine(stateDirectory: state)
        await restored.restore()
        let restoredSnapshot = await restored.currentSnapshots().first { $0.id == meta.id }
        XCTAssertEqual(restoredSnapshot?.state, .failed)
        XCTAssertEqual(restoredSnapshot?.error, failed.error)
        await restored.shutdown()
    }

    func testDownloadWriteFailureQuarantinesTorrentWithoutRecreatingFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let meta = fixture(payload)
        let file = root.appendingPathComponent(meta.name)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
        try FileManager.default.removeItem(at: file)
        do { try await engine.exerciseQuarantineWrite(meta.id, block: Data(payload.prefix(16_384))); XCTFail("Missing payload writes must fail") }
        catch TorrentError.storage { }
        let snapshot = await engine.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertNotNil(snapshot?.error)
        XCTAssertEqual(snapshot?.downloadRate, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await engine.shutdown()
    }
}

private extension TorrentEngine {
    func exerciseFailedPeerUpload(_ id: String) async throws {
        guard let session = sessions[id] else { throw TorrentError.storage("Missing test session") }
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
        let transport = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        transport.start(queue: .global())
        let connection = PeerConnection(connection: transport)
        await connection.close()
        let key = UUID()
        var peer = ActivePeer(connection: connection, endpoint: endpoint, availability: PieceBitset(count: session.wanted.count))
        peer.interested = true
        session.peers[key] = peer
        defer { session.peers.removeValue(forKey: key) }
        try await upload(id, key: key, index: 0, begin: 0, length: 16_384)
    }

    func exerciseQuarantineUpload(_ id: String) async throws {
        guard let session = sessions[id] else { throw TorrentError.storage("Missing test session") }
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
        let key = UUID()
        var peer = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: session.wanted.count))
        peer.interested = true
        session.peers[key] = peer
        try await upload(id, key: key, index: 0, begin: 0, length: 16_384)
    }

    func exerciseQuarantineWrite(_ id: String, block: Data) async throws {
        guard let session = sessions[id] else { throw TorrentError.storage("Missing test session") }
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
        let key = UUID()
        var peer = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: session.wanted.count))
        peer.pending[BlockRequest(piece: 0, begin: 0, length: block.count)] = Date()
        session.peers[key] = peer
        try await budget.acquire(block.count)
        try await receiveBlock(id, key: key, index: 0, begin: 0, block: block)
    }
}
