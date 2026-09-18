import Foundation
import Network
import Testing
import TorrentCore
@testable import TorrentWire

struct DiscoveryTests {
    /// Explicit opt-in only: contacts public bootstrap servers but never downloads payload data.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TORRENZA_PUBLIC_DHT"] == "1"))
    func publicUbuntuDiscovery() async throws {
        let url = URL(string: "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso.torrent")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let metainfo = try MetainfoParser.parse(data)
        let client = DHTClient()
        do {
            let peers = try await client.peers(infoHash: metainfo.infoHash)
            #expect(!peers.isEmpty)
            let snapshot = await client.contactsSnapshot()
            let contacts = try #require(try JSONSerialization.jsonObject(with: snapshot) as? [Any])
            #expect(!contacts.isEmpty)
            print("PUBLIC_DHT infoHash=\(metainfo.infoHash.hexString) peers=\(peers.count) contacts=\(contacts.count)")
            await client.stop()
        } catch { await client.stop(); throw error }
    }

    @Test func bep42PublishedVectors() throws {
        for (host, hex) in [
            ("124.31.75.21", "5fbfbff10c5d6a4ec8a88e4c6ab4c28b95eee401"),
            ("21.75.31.124", "5a3ce9c14e7a08645677bbd1cfe7d8f956d53256"),
            ("65.23.51.170", "a5d43220bc8f112a3d426c84764f8c2a1150e616"),
            ("84.124.73.14", "1b0321dd1bb1fe518101ceef99462b947a01ff41"),
            ("43.213.53.83", "e56f6cbf5b7c4be0237986d5243b87aa6d51305a")
        ] {
            let id = try #require(Data(hex: hex))
            #expect(DHTClient.validNodeID(id, host: host))
            #expect(DHTClient.makeNodeID(host: host, random: id) == id)
            var invalid = id; invalid[0] ^= 128
            #expect(!DHTClient.validNodeID(invalid, host: host))
        }
        #expect(DHTClient.validNodeID(Data(repeating: 0, count: 20), host: "127.0.0.1"))
    }
    @Test func extensionHandshakeRoundTripAndLimits() throws {
        let decoded = try PeerExtensions.parseHandshake(PeerExtensions.extendedHandshake(metadataSize: 17000))
        #expect(decoded.metadataID == 1)
        #expect(decoded.pexID == 2)
        #expect(decoded.metadataSize == 17000)
        #expect(try PeerExtensions.parseHandshake(PeerExtensions.extendedHandshake(allowPEX: false)).pexID == nil)
        #expect(throws: TorrentError.self) {
            try PeerExtensions.parseHandshake(Bencode.encode(.dictionary(["metadata_size": .integer(16 * 1024 * 1024 + 1)])))
        }
        let disabled = try PeerExtensions.parseHandshake(Bencode.encode(.dictionary(["m": .dictionary(["ut_metadata": .integer(0)])])))
        #expect(disabled.metadataID == nil)
    }
    @Test func metadataChunkBoundaries() throws {
        let full = Data(repeating: 0xFF, count: 16384)
        let first = try PeerExtensions.parseMetadata(PeerExtensions.metadataData(piece: 0, totalSize: 16385, block: full))
        #expect(first.block == full)
        let tail = try PeerExtensions.parseMetadata(PeerExtensions.metadataData(piece: 1, totalSize: 16385, block: Data([0])))
        #expect(tail.block == Data([0]))
        #expect(tail.totalSize == 16385)
        #expect(try PeerExtensions.parseMetadata(PeerExtensions.metadataRequest(piece: 0)).type == 0)
        #expect(try PeerExtensions.parseMetadata(PeerExtensions.metadataReject(piece: 0)).type == 2)
        #expect(throws: TorrentError.self) { try PeerExtensions.parseMetadata(PeerExtensions.metadataData(piece: 1, totalSize: 16385, block: full)) }
        #expect(throws: TorrentError.self) { try PeerExtensions.parseMetadata(PeerExtensions.metadataData(piece: 2, totalSize: 16385, block: Data([0]))) }
        #expect(throws: TorrentError.self) { try PeerExtensions.parseMetadata(PeerExtensions.metadataRequest(piece: -1)) }
    }
    @Test func pexIPv4IPv6RoundTripAndMalformedLength() throws {
        let endpoints = [PeerEndpoint(host: "192.0.2.1", port: 51413), PeerEndpoint(host: "2001:db8::1", port: 6881)]
        #expect(Set(try PeerExtensions.parsePEX(PeerExtensions.encodePEX(added: endpoints))) == Set(endpoints))
        #expect(throws: TorrentError.self) { try PeerExtensions.parsePEX(Bencode.encode(.dictionary(["added": .bytes(Data([1, 2, 3]))]))) }
        #expect(throws: TorrentError.self) {
            try PeerExtensions.parsePEX(Bencode.encode(.dictionary(["added": .bytes(Data([1, 2, 3, 4, 0, 1])), "added.f": .bytes(Data())])))
        }
    }
    @Test func dhtLocalDiscoveryAnnounceAndPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = directory.appendingPathComponent("contacts.json")
        let router = DHTClient(bootstrapNodes: [])
        try await router.start()
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: await router.boundPort)
        let publisher = DHTClient(bootstrapNodes: [endpoint], persistenceURL: persistence)
        let hash = Data(repeating: 23, count: 20)
        #expect(try await publisher.peers(infoHash: hash).isEmpty)
        await publisher.announce(infoHash: hash, port: 51413)
        let consumer = DHTClient(bootstrapNodes: [endpoint])
        let discovered = try await consumer.peers(infoHash: hash)
        #expect(discovered.contains(PeerEndpoint(host: "127.0.0.1", port: 51413)))
        await publisher.stop()
        #expect(FileManager.default.fileExists(atPath: persistence.path))
        let exported = await publisher.contactsSnapshot()
        let restored = DHTClient(bootstrapNodes: [], persistedContacts: exported)
        #expect(try await restored.peers(infoHash: hash).contains(PeerEndpoint(host: "127.0.0.1", port: 51413)))
        let imported = DHTClient(bootstrapNodes: [])
        try await imported.importContacts(exported)
        #expect(try await imported.peers(infoHash: hash).contains(PeerEndpoint(host: "127.0.0.1", port: 51413)))
        await #expect(throws: TorrentError.self) { try await imported.importContacts(Data(repeating: 0, count: 256 * 1024 + 1)) }
        await imported.stop(); await restored.stop(); await consumer.stop(); await router.stop()
    }
    @Test func dhtIndependentFakeNodeAndWrongTransaction() async throws {
        let fake = try FakeDHTNode()
        let port = try await fake.start()
        let client = DHTClient(bootstrapNodes: [PeerEndpoint(host: "127.0.0.1", port: port)])
        let discovered = try await client.peers(infoHash: Data(repeating: 4, count: 20))
        #expect(discovered == [PeerEndpoint(host: "192.0.2.8", port: 6881)])
        #expect(fake.receivedPort == (await client.boundPort))
        await client.stop(); fake.stop()
        let incorrect = try FakeDHTNode(wrongTransaction: true)
        let badPort = try await incorrect.start()
        let badClient = DHTClient(bootstrapNodes: [PeerEndpoint(host: "127.0.0.1", port: badPort)])
        await #expect(throws: TorrentError.self) { try await badClient.peers(infoHash: Data(repeating: 4, count: 20)) }
        await badClient.stop(); incorrect.stop()
    }
    @Test func dhtIPv6AndConcurrentLookups() async throws {
        let router = DHTClient(bootstrapNodes: [])
        try await router.start()
        let endpoint = PeerEndpoint(host: "::1", port: await router.boundPort)
        let publisher = DHTClient(bootstrapNodes: [endpoint])
        let first = Data(repeating: 12, count: 20), second = Data(repeating: 13, count: 20)
        async let a = publisher.peers(infoHash: first)
        async let b = publisher.peers(infoHash: second)
        _ = try await (a, b)
        await publisher.announce(infoHash: first, port: 4444)
        let consumer = DHTClient(bootstrapNodes: [endpoint])
        #expect(try await consumer.peers(infoHash: first).contains(PeerEndpoint(host: "::1", port: 4444)))
        await consumer.stop(); await publisher.stop(); await router.stop()
    }
    @Test func dhtRealTimeout() async throws {
        let silent = try FakeDHTNode(silent: true)
        let port = try await silent.start()
        let client = DHTClient(bootstrapNodes: [PeerEndpoint(host: "127.0.0.1", port: port)])
        let began = ContinuousClock.now
        await #expect(throws: TorrentError.self) { try await client.peers(infoHash: Data(repeating: 5, count: 20)) }
        let elapsed = began.duration(to: .now)
        #expect(elapsed >= .seconds(2))
        #expect(elapsed < .seconds(5))
        await client.stop(); silent.stop()
    }
    @Test func dhtCancellationAndHashValidation() async throws {
        let silent = try FakeDHTNode(silent: true)
        let port = try await silent.start()
        let client = DHTClient(bootstrapNodes: [PeerEndpoint(host: "127.0.0.1", port: port)])
        await #expect(throws: TorrentError.self) { try await client.peers(infoHash: Data()) }
        let task = Task { try await client.peers(infoHash: Data(repeating: 5, count: 20)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await client.stop(); silent.stop()
    }
}

/// Independent, literal KRPC responder avoids testing only two copies of the same node implementation.
private final class FakeDHTNode: @unchecked Sendable {
    let listener: NWListener
    let wrongTransaction: Bool
    let silent: Bool
    private let lock = NSLock()
    private var sourcePort: UInt16?
    var receivedPort: UInt16? { lock.lock(); defer { lock.unlock() }; return sourcePort }
    private func record(_ endpoint: NWEndpoint) {
        if case .hostPort(_, let port) = endpoint { lock.lock(); sourcePort = port.rawValue; lock.unlock() }
    }
    init(wrongTransaction: Bool = false, silent: Bool = false) throws {
        listener = try NWListener(using: .udp, on: .any); self.wrongTransaction = wrongTransaction; self.silent = silent
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self, wrongTransaction, silent] connection in
            self?.record(connection.endpoint)
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                guard let data, let query = try? Bencode.decode(data).dictionaryValue,
                      let transaction = query["t"]?.dataValue else { connection.cancel(); return }
                if silent { DispatchQueue.global().asyncAfter(deadline: .now() + 4) { connection.cancel() }; return }
                let reply = Bencode.encode(.dictionary([
                    "t": .bytes(wrongTransaction ? Data([0]) : transaction), "y": .bytes(Data("r".utf8)),
                    "r": .dictionary(["id": .bytes(Data(repeating: 42, count: 20)), "token": .bytes(Data([11, 12])),
                                      "values": .list([.bytes(Data([192, 0, 2, 8, 0x1a, 0xe1]))])])
                ]))
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = FakeReady()
        return try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { ready.finish(.success(listener.port!.rawValue)) }
                if case .failed(let error) = state { ready.finish(.failure(error)) }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel() }
}
private final class FakeReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?
    func set(_ continuation: CheckedContinuation<UInt16, any Error>) { lock.lock(); self.continuation = continuation; lock.unlock() }
    func finish(_ result: Result<UInt16, any Error>) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(with: result) }
}
