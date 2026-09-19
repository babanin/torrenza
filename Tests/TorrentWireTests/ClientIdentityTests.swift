import Foundation
import Testing
import TorrentCore
@testable import TorrentWire

struct ClientIdentityTests {
    @Test func peerHandshakeAdvertisesRandomizedQBittorrentIdentity() throws {
        let identities = (0..<64).map { _ in ClientIdentity.makePeerID() }
        #expect(Set(identities).count == identities.count)
        for identity in identities {
            let packet = try PeerHandshake(infoHash: Data(repeating: 7, count: 20), peerID: identity).encode()
            #expect(packet.count == 68)
            #expect(Data(packet[48..<56]) == Data("-qB5100-".utf8))
            #expect(try PeerHandshake.decode(packet).peerID == identity)
        }
    }

    @Test func extensionHandshakeOmitsOptionalAddressDisclosures() throws {
        let values = try #require(try Bencode.decode(PeerExtensions.extendedHandshake()).dictionaryValue)
        #expect(values["v"]?.stringValue == "qBittorrent/5.1.0")
        for key in ["yourip", "ipv4", "ipv6", "ip"] { #expect(values[key] == nil) }
    }

    @Test func trackerAnnouncesOmitExplicitSourceAddress() throws {
        let request = TrackerRequest(infoHash: Data(repeating: 1, count: 20), peerID: ClientIdentity.makePeerID(), port: 6881, left: 1)
        let url = try TrackerClient.announceURL(URL(string: "https://tracker.invalid/announce")!, request: request)
        let fields = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!fields.contains { ["ip", "ipv4", "ipv6"].contains($0.name) })
        let packet = try TrackerClient.udpAnnouncePacket(connectionID: 1, transactionID: 2, request: request)
        #expect(Data(packet[84..<88]) == Data(repeating: 0, count: 4))
        #expect(Data(packet[36..<44]) == Data("-qB5100-".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func httpTrackerReceivesQBittorrentUserAgent() async throws {
        let listener = try WireTestListener(); defer { listener.close() }
        let port = try await listener.start()
        let request = TrackerRequest(infoHash: Data(repeating: 1, count: 20), peerID: ClientIdentity.makePeerID(), port: 6881, left: 1)
        let announcing = Task { try await TrackerClient().announce(url: URL(string: "http://127.0.0.1:\(port)/announce")!, request: request) }
        defer { announcing.cancel() }
        var incoming = listener.incoming.makeAsyncIterator()
        let server = NetworkTransport(connection: try #require(await incoming.next()))
        try await server.start(); defer { server.close() }
        var headers = Data()
        while !headers.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)) {
            #expect(headers.count < 16 * 1024)
            guard headers.count < 16 * 1024 else { return }
            headers.append(try await server.receiveExactly(1, timeout: 5))
        }
        let text = String(decoding: headers, as: UTF8.self)
        #expect(text.lowercased().contains("user-agent: qbittorrent/5.1.0\r\n"))
        #expect(!text.contains("Torrenza"))
        #expect(!text.lowercased().contains("\r\ncookie:"))
        #expect(!text.lowercased().contains("\r\nauthorization:"))
        let body = Bencode.encode(.dictionary(["interval": .integer(60), "peers": .bytes(Data())]))
        try await server.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        #expect(try await announcing.value.peers.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func dhtQueriesAdvertiseBinaryClientVersion() async throws {
        let listener = try WireTestListener(udp: true); defer { listener.close() }
        let port = try await listener.start()
        let client = DHTClient(bootstrapNodes: [.init(host: "127.0.0.1", port: port)])
        do {
            let discovering = Task { try await client.peers(infoHash: Data(repeating: 9, count: 20)) }
            defer { discovering.cancel() }
            var incoming = listener.incoming.makeAsyncIterator()
            let server = NetworkTransport(connection: try #require(await incoming.next()))
            try await server.start(); defer { server.close() }
            let query = try #require(try Bencode.decode(try await server.receiveDatagram()).dictionaryValue)
            #expect(query["v"]?.dataValue == Data([0x71, 0x42, 5, 1]))
            #expect(query["ip"] == nil)
            let args = try #require(query["a"]?.dictionaryValue)
            #expect(args["id"]?.dataValue?.count == 20)
            #expect(args["ip"] == nil)
            let transaction = try #require(query["t"]?.dataValue)
            try await server.send(Bencode.encode(.dictionary([
                "t": .bytes(transaction), "y": .bytes(Data("r".utf8)),
                "r": .dictionary(["id": .bytes(Data(repeating: 42, count: 20)), "nodes": .bytes(Data())])
            ])))
            #expect(try await discovering.value.isEmpty)
            await client.stop()
        } catch { await client.stop(); throw error }
    }

    @Test(.timeLimit(.minutes(1))) func dhtResponsesAdvertiseBinaryClientVersion() async throws {
        let router = DHTClient(bootstrapNodes: [])
        do {
            try await router.start()
            let transport = try NetworkTransport(endpoint: .init(host: "127.0.0.1", port: await router.boundPort), udp: true)
            try await transport.start(); defer { transport.close() }
            for method in ["ping", "unsupported"] {
                try await transport.send(Bencode.encode(.dictionary([
                    "t": .bytes(Data([1, 2])), "y": .bytes(Data("q".utf8)), "q": .bytes(Data(method.utf8)),
                    "a": .dictionary(["id": .bytes(Data(repeating: 9, count: 20))])
                ])))
                let reply = try #require(try Bencode.decode(try await transport.receiveDatagram()).dictionaryValue)
                #expect(reply["v"]?.dataValue == Data([0x71, 0x42, 5, 1]))
                #expect(reply["y"]?.stringValue == (method == "ping" ? "r" : "e"))
            }
            await router.stop()
        } catch { await router.stop(); throw error }
    }
}
