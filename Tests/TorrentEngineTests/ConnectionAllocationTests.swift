import XCTest
import Foundation
import Network
import TorrentCore
import TorrentWire
@testable import TorrentEngine

final class ConnectionAllocationTests: XCTestCase, @unchecked Sendable {
    func testGlobalAndPerTorrentHandshakeAdmission() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let result = await engine.exerciseAdmissionLimits()
        XCTAssertEqual(result.perTorrent, 16)
        XCTAssertEqual(result.global, 64)
        XCTAssertTrue(result.globalBlocked)
        XCTAssertTrue(result.connectionCapBlocked)
    }

    func testUnusedSlotsAreBorrowedAndReclaimedForWaitingTorrent() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let result = try await engine.exerciseBorrowedSlots()
        XCTAssertEqual(result.borrowed, 8)
        XCTAssertEqual(result.donor, 4)
        XCTAssertEqual(result.receiverSlots, 4)
        XCTAssertLessThanOrEqual(result.total, 8)
        XCTAssertEqual(result.budgetAfterStop, 0)
    }

    func testReclaimsOnlyAsManySlotsAsCandidatesWaiting() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let result = try await engine.exerciseBorrowedSlots(candidateCount: 1)
        XCTAssertEqual(result.donor, 7)
        XCTAssertEqual(result.receiverSlots, 1)
        XCTAssertEqual(result.total, 8)
        XCTAssertEqual(result.budgetAfterStop, 0)
    }

    func testLiveBudgetReductionRetiresPersistentReceiveReservations() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let result = try await engine.exerciseMemoryReclamation()
        XCTAssertLessThan(result.used, 31 * 1024 * 1024)
        XCTAssertTrue(result.payloadAdmitted)
        XCTAssertEqual(result.finalUsed, 0)
    }
}

extension TorrentEngine {
    private func allocationSession(_ number: UInt8) -> EngineSession {
        let meta = TorrentMetainfo(infoHash: Data(repeating: number, count: 20), rawInfo: Data(), name: "slots", pieceLength: 1_048_576, pieceHashes: [Data(repeating: 0, count: 20)], files: [TorrentFile(index: 0, path: ["slots"], length: 1_048_576, offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
        let record = EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/private/tmp"), selectedFiles: [0], seedRatio: nil, downloaded: 0, uploaded: 0, wantedRunning: true, verified: PieceBitset(count: 1))
        let session = EngineSession(record: record)
        session.snapshot.state = .downloading
        sessions[meta.id] = session
        return session
    }

    fileprivate func exerciseAdmissionLimits() -> (perTorrent: Int, global: Int, globalBlocked: Bool, connectionCapBlocked: Bool) {
        configuration.maxPeers = 1000
        let session = allocationSession(1)
        for _ in 0..<20 { _ = reserveConnection(for: session.record.metainfo.id) }
        let perTorrent = handshakes(for: session.record.metainfo.id)
        for _ in 0..<64 { _ = reserveConnection(for: nil) }
        let global = connectionAdmissions.count
        let blocked = reserveConnection(for: nil) == nil
        connectionAdmissions.removeAll()
        configuration.maxPeers = 1
        _ = reserveConnection(for: nil)
        let capBlocked = reserveConnection(for: session.record.metainfo.id) == nil
        connectionAdmissions.removeAll()
        sessions.removeAll()
        return (perTorrent, global, blocked, capBlocked)
    }

    fileprivate func exerciseBorrowedSlots(candidateCount: Int = 8) async throws -> (borrowed: Int, donor: Int, receiverSlots: Int, total: Int, budgetAfterStop: Int) {
        configuration.maxPeers = 8
        let donor = allocationSession(2), receiver = allocationSession(3)
        let donorID = donor.record.metainfo.id, receiverID = receiver.record.metainfo.id
        // A torrent with no discovered candidates leaves all capacity borrowable.
        for index in 0..<8 { donor.candidates.append(PeerEndpoint(host: "127.0.0.1", port: UInt16(1200 + index))) }
        connectCandidates(donorID)
        let borrowed = handshakes(for: donorID)
        for task in donor.connectionTasks.values { task.cancel() }
        // Convert synthetic admissions to established idle peers without opening
        // sockets, so reclamation is deterministic and independent of timing.
        connectionAdmissions.removeAll()
        donor.connecting.removeAll(); donor.candidates.removeAll()
        for index in 0..<8 {
            let endpoint = PeerEndpoint(host: "127.0.0.1", port: UInt16(2200 + index))
            donor.peers[UUID()] = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: 1))
        }
        for index in 0..<candidateCount { receiver.candidates.append(PeerEndpoint(host: "127.0.0.1", port: UInt16(3200 + index))) }
        await rebalanceConnections()
        let counts = (donor.peers.count, handshakes(for: receiverID), totalPeers)
        await stopSession(donorID, state: .paused)
        await stopSession(receiverID, state: .paused)
        for task in Array(backgroundTasks.values) { task.cancel(); await task.value }
        sessions.removeAll()
        return (borrowed, counts.0, counts.1, counts.2, await budget.used)
    }

    fileprivate func exerciseMemoryReclamation() async throws -> (used: Int, payloadAdmitted: Bool, finalUsed: Int) {
        configuration.maxPeers = 1000
        let session = allocationSession(4)
        await budget.resize(limit: 256 * 1024 * 1024)
        for index in 0..<40 {
            let endpoint = PeerEndpoint(host: "127.0.0.1", port: UInt16(4200 + index))
            var peer = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: 1))
            peer.receiveReservation = 1024 * 1024
            try await budget.acquire(peer.receiveReservation)
            session.peers[UUID()] = peer
        }
        await budget.resize(limit: 32 * 1024 * 1024)
        await rebalanceConnections()
        let used = await budget.used
        let admitted = await budget.tryAcquire(16_384)
        if admitted { await budget.release(16_384) }
        await stopSession(session.record.metainfo.id, state: .paused)
        for task in Array(backgroundTasks.values) { task.cancel(); await task.value }
        sessions.removeAll()
        return (used, admitted, await budget.used)
    }
}
