import XCTest
import Foundation
import Network
import CryptoKit
import TorrentCore
import TorrentWire
@testable import TorrentEngine

extension EngineTests {
    func testDeepRequestPipelineRespectsRemoteQueueAndReturnsReservations() async throws {
        let capacities: [(remote: Int?, payloadBlocks: Int)] = [(nil, 512), (5, 512), (64, 512), (nil, 4)]
        for capacity in capacities {
            let remoteLimit = capacity.remote
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = Data(repeating: 42, count: 4 * 1024 * 1024)
            let meta = TorrentMetainfo(infoHash: Data(Insecure.SHA1.hash(data: payload)), rawInfo: Data("de".utf8), name: "pipeline.bin", pieceLength: payload.count, pieceHashes: [Data(Insecure.SHA1.hash(data: payload))], files: [TorrentFile(index: 0, path: ["pipeline.bin"], length: Int64(payload.count), offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
            let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
            let pair = try await PipelinePeerPair.open(meta: meta)
            do {
                _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
                let result = try await engine.exercisePipeline(meta.id, connection: pair.client, remoteLimit: remoteLimit, payloadBlocks: capacity.payloadBlocks)
                XCTAssertEqual(result.pending, min(128, remoteLimit ?? 128, capacity.payloadBlocks))
                XCTAssertEqual(result.used, result.pending * 16_384)
                XCTAssertEqual(result.afterDisconnect, 0)
                XCTAssertLessThanOrEqual(result.highWaterMark, capacity.payloadBlocks * 16_384)
                await engine.shutdown()
                await pair.close()
            } catch { await engine.shutdown(); await pair.close(); throw error }
        }
    }

    func testPauseDrainsVerificationWaitingForGlobalSlot() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 16_384)
        let meta = fixture(payload)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
            try await engine.queueBlockedVerification(meta.id, block: payload)
            await engine.pause(meta.id)
            let state = await engine.pipelineState(meta.id)
            XCTAssertEqual(state.used, 0)
            XCTAssertEqual(state.queued, 0)
            XCTAssertFalse(state.hasWorker)
            XCTAssertFalse(state.verified)
            await engine.releaseBlockedVerificationSlots()
            await engine.shutdown()
        } catch { await engine.releaseBlockedVerificationSlots(); await engine.shutdown(); throw error }
    }

    func testFailingVerificationWorkerQuarantinesWithoutAwaitingItself() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 16_384)
        let meta = fixture(payload)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
            try await engine.queueBlockedVerification(meta.id, block: payload)
            try FileManager.default.removeItem(at: root.appendingPathComponent(meta.name))
            await engine.releaseBlockedVerificationSlots()
            _ = try await waitFor(engine, id: meta.id, state: .failed, timeout: 3)
            let state = await engine.pipelineState(meta.id)
            XCTAssertEqual(state.used, 0)
            XCTAssertFalse(state.hasWorker)
            XCTAssertFalse(state.verified)
            await engine.shutdown()
        } catch { await engine.releaseBlockedVerificationSlots(); await engine.shutdown(); throw error }
    }

    func testBlockedAnnouncementWriterDoesNotStallPayloadOrVerification() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 65_536)
        let meta = fixture(payload)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        let pair = try await PipelinePeerPair.open(meta: meta)
        // Deterministically hold the announcement writer instead of relying on
        // platform TCP buffer sizes to make a nonreading recipient stall.
        let gate = AsyncStream<Void>.makeStream()
        let blockedWriter = Task { for await _ in gate.stream {} }
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, startPaused: true)
            let key = try await engine.receivePieceWithBlockedAnnouncements(meta.id, connection: pair.client, writer: blockedWriter, block: Data(payload.prefix(16_384)))
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if await engine.blockedAnnouncementState(meta.id, key: key).verified { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let state = await engine.blockedAnnouncementState(meta.id, key: key)
            XCTAssertTrue(state.verified, "Piece verification must finish while its recipient's announcement writer is blocked")
            XCTAssertTrue(state.hasWriter)
            XCTAssertFalse(blockedWriter.isCancelled)
            XCTAssertEqual(state.pending, 1)
            XCTAssertEqual(state.bytes, 1, "Repeated announcements occupy a fixed bitmap sized to this torrent")
            XCTAssertEqual(state.payloadReservations, 0)
            await engine.pause(meta.id)
            XCTAssertTrue(blockedWriter.isCancelled)
            gate.continuation.finish()
            await blockedWriter.value
            await engine.shutdown()
            await pair.close()
        } catch {
            blockedWriter.cancel(); gate.continuation.finish()
            await engine.shutdown(); await pair.close(); throw error
        }
    }

    func testSlowAnnouncementQueueUsesFixedBitmapAndCoalescesDuplicates() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-announcement-test"))
        let meta = fixture(Data(repeating: 42, count: 16_384))
        let result = try await engine.exerciseAnnouncementCoalescing(meta)
        XCTAssertEqual(result.pending, 1000)
        XCTAssertEqual(result.bytes, 125)
        await engine.shutdown()
    }
}

private extension TorrentEngine {
    func exercisePipeline(_ id: String, connection: PeerConnection, remoteLimit: Int?, payloadBlocks: Int) async throws -> (pending: Int, used: Int, afterDisconnect: Int, highWaterMark: Int) {
        let session = try XCTUnwrap(sessions[id])
        configuration.downloadRequestWindow = 128
        await budget.resize(limit: 1024 * 1024 + payloadBlocks * 16_384)
        session.snapshot.state = .downloading
        let key = UUID()
        var peer = ActivePeer(connection: connection, endpoint: PeerEndpoint(host: "127.0.0.1", port: 1), availability: PieceBitset(count: session.wanted.count))
        peer.choked = false
        peer.remoteRequestQueueLimit = remoteLimit
        session.peers[key] = peer
        session.replacePeerAvailability(key: key, availability: PieceBitset(count: session.wanted.count, repeating: true))
        await fillRequests(id, key: key)
        let pending = session.peers[key]?.pending.count ?? 0
        let used = await budget.used
        let highWaterMark = await budget.highWaterMark
        await disconnect(id, key: key)
        return (pending, used, await budget.used, highWaterMark)
    }

    func queueBlockedVerification(_ id: String, block: Data) async throws {
        let session = try XCTUnwrap(sessions[id])
        try await verificationSlots.acquire(4)
        session.snapshot.state = .downloading
        let key = UUID()
        let connection = try PeerConnection(endpoint: PeerEndpoint(host: "127.0.0.1", port: 1))
        var peer = ActivePeer(connection: connection, endpoint: PeerEndpoint(host: "127.0.0.1", port: 1), availability: PieceBitset(count: session.wanted.count))
        peer.pending[BlockRequest(piece: 0, begin: 0, length: block.count)] = Date()
        session.peers[key] = peer
        session.pieceWork[0] = PieceWork(requested: [0])
        try await budget.acquire(block.count)
        try await receiveBlock(id, key: key, index: 0, begin: 0, block: block)
    }
    func releaseBlockedVerificationSlots() async {
        let used = await verificationSlots.used
        if used == 4 { await verificationSlots.release(4) }
    }
    func pipelineState(_ id: String) async -> (used: Int, queued: Int, hasWorker: Bool, verified: Bool) {
        let session = sessions[id]!
        return (await budget.used, session.verificationQueue.count, session.verificationTask != nil, session.record.verified[0])
    }
    func receivePieceWithBlockedAnnouncements(_ id: String, connection: PeerConnection, writer: Task<Void, Never>, block: Data) async throws -> UUID {
        let session = try XCTUnwrap(sessions[id])
        session.record.wantedRunning = true
        session.snapshot.state = .downloading
        let key = UUID()
        var peer = ActivePeer(connection: connection, endpoint: PeerEndpoint(host: "127.0.0.1", port: 1), availability: PieceBitset(count: session.wanted.count))
        peer.announcementTask = writer
        for begin in [0, 16_384] {
            peer.pending[BlockRequest(piece: 0, begin: begin, length: block.count)] = Date()
        }
        session.peers[key] = peer
        session.pieceWork[0] = PieceWork(requested: [0, 16_384])
        try await budget.acquire(block.count * 2)
        try await receiveBlock(id, key: key, index: 0, begin: 0, block: block)
        try await receiveBlock(id, key: key, index: 0, begin: 16_384, block: block)
        return key
    }

    func blockedAnnouncementState(_ id: String, key: UUID) async -> (verified: Bool, hasWriter: Bool, pending: Int, bytes: Int, payloadReservations: Int) {
        let session = sessions[id]!
        if session.record.verified[0] {
            for _ in 0..<1000 { queueAnnouncement(id, key: key, have: 0) }
        }
        let peer = session.peers[key]
        return (session.record.verified[0], peer?.announcementTask != nil, peer?.pendingHaves?.setCount ?? 0, peer?.pendingHaves?.bytes.count ?? 0, await budget.used)
    }

    func exerciseAnnouncementCoalescing(_ source: TorrentMetainfo) throws -> (pending: Int, bytes: Int) {
        let meta = TorrentMetainfo(infoHash: source.infoHash, rawInfo: source.rawInfo, name: source.name, pieceLength: 16_384, pieceHashes: Array(repeating: Data(repeating: 0, count: 20), count: 1000), files: [TorrentFile(index: 0, path: [source.name], length: 16_384_000, offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
        let record = EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/tmp"), selectedFiles: [0], seedRatio: 0, downloaded: 0, uploaded: 0, wantedRunning: true, verified: PieceBitset(count: 1000))
        let session = EngineSession(record: record)
        sessions[meta.id] = session
        let key = UUID(), endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
        session.peers[key] = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: 1))
        for _ in 0..<2 {
            for index in 0..<1000 { queueAnnouncement(meta.id, key: key, have: index) }
        }
        return (session.peers[key]!.pendingHaves!.setCount, session.peers[key]!.pendingHaves!.bytes.count)
    }
}

private final class PipelinePeerPair: @unchecked Sendable {
    let listener: NWListener
    let client: PeerConnection
    let server: PeerConnection
    init(listener: NWListener, client: PeerConnection, server: PeerConnection) {
        self.listener = listener; self.client = client; self.server = server
    }
    static func open(meta: TorrentMetainfo) async throws -> PipelinePeerPair {
        let listener = try NWListener(using: .tcp, on: .any)
        let incoming = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listener.newConnectionHandler = { incoming.continuation.yield($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "pipeline.test.listener"))
        }
        let client = try PeerConnection(endpoint: PeerEndpoint(host: "127.0.0.1", port: port))
        let connecting = Task { try await client.connect(infoHash: meta.infoHash, peerID: Data(repeating: 1, count: 20)) }
        var iterator = incoming.stream.makeAsyncIterator()
        let raw = await iterator.next()
        let server = PeerConnection(connection: try XCTUnwrap(raw))
        _ = try await server.receiveHandshake()
        try await server.sendHandshake(infoHash: meta.infoHash, peerID: Data(repeating: 2, count: 20))
        _ = try await connecting.value
        return PipelinePeerPair(listener: listener, client: client, server: server)
    }
    func close() async { listener.cancel(); await client.close(); await server.close() }
}
