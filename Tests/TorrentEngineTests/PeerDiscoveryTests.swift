import XCTest
import Foundation
import Network
import TorrentCore
import TorrentWire
@testable import TorrentEngine

extension EngineTests {
    func testPublicDHTConnectsWhileTrackerResponseIsDelayed() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = try DiscoveryTracker()
        let trackerPort = try await tracker.start()
        defer { tracker.close() }
        let original = fixture(Data(repeating: 11, count: 32_768))
        let meta = TorrentMetainfo(infoHash: original.infoHash, rawInfo: original.rawInfo, name: original.name,
                                  pieceLength: original.pieceLength, pieceHashes: original.pieceHashes, files: original.files,
                                  trackerTiers: [[URL(string: "http://127.0.0.1:\(trackerPort)/announce")!]], isPrivate: false, isMultiFile: false)
        let router = DHTClient(bootstrapNodes: [])
        try await router.start()
        let bootstrap = PeerEndpoint(host: "127.0.0.1", port: await router.boundPort)
        let publisher = DHTClient(bootstrapNodes: [bootstrap])
        _ = try await publisher.peers(infoHash: meta.infoHash)
        await publisher.announce(infoHash: meta.infoHash, port: 9)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
            await engine.prepareDiscoveryFixture(meta.id, bootstrap: [bootstrap], maxPeers: 128)
            let discovery = Task { await engine.discover(meta.id) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var admitted = false
            while ContinuousClock.now < deadline {
                admitted = await engine.discoveryContains(meta.id, endpoint: PeerEndpoint(host: "127.0.0.1", port: 9))
                if admitted, await tracker.observation.headers != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(admitted, "Public DHT must admit peers before the tracker responds")
            let headers = await tracker.observation.headers
            XCTAssertTrue(headers?.contains("numwant=128") == true)
            tracker.respond()
            await discovery.value
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.swarm.announceInterval, 90)
            await engine.shutdown(); await publisher.stop(); await router.stop()
        } catch {
            tracker.respond()
            await engine.shutdown(); await publisher.stop(); await router.stop()
            throw error
        }
    }

    func testPausedDiscoveryIgnoresDelayedTrackerResponse() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = try DiscoveryTracker()
        let port = try await tracker.start()
        defer { tracker.close() }
        let original = fixture(Data(repeating: 14, count: 32_768))
        let meta = TorrentMetainfo(infoHash: original.infoHash, rawInfo: original.rawInfo, name: original.name,
                                  pieceLength: original.pieceLength, pieceHashes: original.pieceHashes, files: original.files,
                                  trackerTiers: [[URL(string: "http://127.0.0.1:\(port)/announce")!]], isPrivate: true, isMultiFile: false)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
            await engine.prepareDiscoveryFixture(meta.id, bootstrap: [], maxPeers: 128)
            let discovery = Task { await engine.discover(meta.id) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await tracker.observation.headers == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let headers = await tracker.observation.headers
            XCTAssertNotNil(headers)
            await engine.pause(meta.id)
            tracker.respond()
            await discovery.value
            let snapshot = await engine.currentSnapshots().first
            XCTAssertEqual(snapshot?.state, .paused)
            XCTAssertNil(snapshot?.swarm.tracker)
            XCTAssertEqual(snapshot?.swarm.announceInterval, 1800)
            await engine.shutdown()
        } catch {
            tracker.respond()
            await engine.shutdown()
            throw error
        }
    }

    func testPrivateDiscoveryDoesNotCreateDHTAndTrackerDemandUsesCapacity() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        let meta = fixture(Data(repeating: 12, count: 32_768))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
        await engine.prepareDiscoveryFixture(meta.id, bootstrap: [], maxPeers: 1_000)
        await engine.discover(meta.id)
        let (hasDHT, demand) = await engine.discoveryState(meta.id)
        XCTAssertFalse(hasDHT)
        XCTAssertEqual(demand, 200)
        let exhausted = await engine.discoveryDemand(meta.id, heldConnections: 1_000)
        XCTAssertEqual(exhausted, 0)
        let almostFull = await engine.discoveryDemand(meta.id, heldConnections: 993)
        XCTAssertEqual(almostFull, 7)
        _ = await engine.discoveryDemand(meta.id, heldConnections: 0)
        let other = fixture(Data(repeating: 13, count: 32_768), name: "borrower.bin")
        _ = try await engine.add(metainfo: other, destination: root, selectedFiles: [0], startPaused: true)
        await engine.prepareDiscoveryFixture(other.id, bootstrap: [], maxPeers: 1_000)
        _ = await engine.discoveryDemand(other.id, heldConnections: 1_000)
        let waitingDemand = await engine.discoveryRequestCount(meta.id)
        XCTAssertEqual(waitingDemand, 200, "A new torrent needs candidates to reclaim borrowed slots")
        _ = await engine.discoveryDemand(other.id, heldConnections: 0)
        await engine.shutdown()
    }
}

private extension TorrentEngine {
    func prepareDiscoveryFixture(_ id: String, bootstrap: [PeerEndpoint], maxPeers: Int) {
        configuration.bootstrapNodes = bootstrap
        configuration.maxPeers = maxPeers
        sessions[id]?.snapshot.state = .downloading
        sessions[id]?.discoveryInProgress = true
        listeningPort = 6881
    }
    func discoveryContains(_ id: String, endpoint: PeerEndpoint) -> Bool { sessions[id]?.knownEndpoints.contains(endpoint) == true }
    func discoveryState(_ id: String) -> (Bool, Int) { (dht != nil, trackerPeerRequestCount(for: id)) }
    func discoveryRequestCount(_ id: String) -> Int { trackerPeerRequestCount(for: id) }
    func discoveryDemand(_ id: String, heldConnections count: Int) -> Int {
        connectionAdmissions = Dictionary(uniqueKeysWithValues: (0..<count).map { _ in
            (UUID(), ConnectionAdmission(sessionID: id, generation: sessions[id]?.generation))
        })
        return trackerPeerRequestCount(for: id)
    }
}

private actor TrackerObservation {
    var headers: String?
    func received(_ headers: String) { self.headers = headers }
}

private final class DiscoveryTracker: @unchecked Sendable {
    let listener: NWListener
    let observation = TrackerObservation()
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var server: Task<Void, Never>?
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.server = Task {
                let transport = NetworkTransport(connection: connection)
                defer { transport.close() }
                do {
                    try await transport.start()
                    var headers = Data()
                    while !headers.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)), headers.count < 16_384 {
                        headers.append(try await transport.receiveExactly(1, timeout: 5))
                    }
                    await self.observation.received(String(decoding: headers, as: UTF8.self))
                    var ready = self.release.stream.makeAsyncIterator()
                    _ = await ready.next()
                    let body = Bencode.encode(.dictionary(["interval": .integer(90), "peers": .bytes(Data())]))
                    try await transport.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
                } catch { }
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "discovery.tracker.test"))
        }
    }
    func respond() { release.continuation.yield(()) }
    func close() { release.continuation.finish(); server?.cancel(); listener.cancel() }
}
