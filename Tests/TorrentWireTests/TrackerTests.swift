import Foundation
import Testing
import TorrentCore
@testable import TorrentWire

struct TrackerTests {
    let request = TrackerRequest(infoHash: Data(repeating: 0xff, count: 20), peerID: Data(repeating: 0x20, count: 20), port: 6881, uploaded: 1, downloaded: 2, left: 3, event: .started)
    @Test func binaryQueryAndPasskeyPreserved() throws {
        let url = try TrackerClient.announceURL(URL(string: "https://example.com/announce?passkey=a%2Fb")!, request: request)
        let text = url.absoluteString
        #expect(text.contains("passkey=a%2Fb&info_hash=%FF%FF"))
        #expect(text.contains("peer_id=%20%20")); #expect(text.contains("event=started")); #expect(text.contains("left=3"))
    }
    @Test func compactIPv4IPv6AndMalformedLists() throws {
        let peers = try TrackerClient.decodeCompactPeers(Data([127,0,0,1,0x1a,0xe1,1,2,3,4,0,0]))
        #expect(peers == [PeerEndpoint(host: "127.0.0.1", port: 6881)])
        let ipv6 = Data([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0x1a,0xe1])
        #expect(try TrackerClient.decodeCompactPeers(ipv6, ipv6: true) == [.init(host: "::1", port: 6881)])
        #expect(throws: (any Error).self) { try TrackerClient.decodeCompactPeers(Data([1,2,3])) }
    }
    @Test func HTTPCountsUnknownAndPresent() throws {
        let unknown = try TrackerClient.decodeHTTPResponse(Bencode.encode(.dictionary(["interval": .integer(60), "peers": .bytes(Data())])))
        #expect(unknown.seeders == nil); #expect(unknown.leechers == nil)
        let populated = try TrackerClient.decodeHTTPResponse(Bencode.encode(.dictionary(["interval": .integer(60), "min interval": .integer(90), "complete": .integer(12), "incomplete": .integer(4), "peers": .list([.dictionary(["ip": .bytes(Data("127.0.0.1".utf8)), "port": .integer(6881)])])])))
        #expect(populated.seeders == 12); #expect(populated.leechers == 4); #expect(populated.interval == 90)
        #expect(populated.peers == [.init(host: "127.0.0.1", port: 6881)])
        #expect(throws: (any Error).self) { try TrackerClient.decodeHTTPResponse(Bencode.encode(.dictionary(["failure reason": .bytes(Data("denied".utf8))]))) }
    }
    @Test func UDPWireLayoutAndTransactionChecks() throws {
        let packet = try TrackerClient.udpAnnouncePacket(connectionID: 123, transactionID: 456, request: request)
        #expect(packet.count == 98)
        let bytes = [UInt8](packet)
        #expect(bytes.integer(at: 0) as UInt64? == 123)
        #expect(bytes.integer(at: 8) as UInt32? == 1)
        #expect(bytes.integer(at: 12) as UInt32? == 456)
        #expect(bytes.integer(at: 56) as UInt64? == 2)
        #expect(bytes.integer(at: 64) as UInt64? == 3)
        #expect(bytes.integer(at: 72) as UInt64? == 1)
        #expect(bytes.integer(at: 80) as UInt32? == 2)
        #expect(bytes.integer(at: 96) as UInt16? == 6881)
        var response = Data(); for value: UInt32 in [1,456,1800,4,12] { response.appendBE(value) }; response.append(contentsOf: [127,0,0,1,0x1a,0xe1])
        let result = try TrackerClient.decodeUDPResponse(response, transactionID: 456)
        #expect(result.seeders == 12); #expect(result.leechers == 4); #expect(result.peers.count == 1)
        #expect(throws: (any Error).self) { try TrackerClient.decodeUDPResponse(response, transactionID: 457) }
        #expect(throws: (any Error).self) { try TrackerClient.decodeUDPResponse(response.prefix(12), transactionID: 456) }
    }
}


extension TrackerTests {
    @Test(.timeLimit(.minutes(1))) func loopbackUDPAnnounce() async throws {
        let listener = try WireTestListener(udp: true); defer { listener.close() }
        let port = try await listener.start()
        let announcing = Task { try await TrackerClient().announce(url: URL(string: "udp://127.0.0.1:\(port)/announce?passkey=fixture")!, request: request) }
        var incoming = listener.incoming.makeAsyncIterator()
        let server = NetworkTransport(connection: try #require(await incoming.next()))
        try await server.start(); defer { server.close() }
        let connect = [UInt8](try await server.receiveDatagram())
        #expect(connect.integer(at: 0) as UInt64? == 0x41727101980)
        let transaction: UInt32 = try #require(connect.integer(at: 12))
        var response = Data(); response.appendBE(UInt32(0)); response.appendBE(transaction); response.appendBE(UInt64(42))
        try await server.send(response)
        let announce = [UInt8](try await server.receiveDatagram())
        #expect(announce.integer(at: 0) as UInt64? == 42)
        #expect(announce.integer(at: 8) as UInt32? == 1)
        #expect(String(decoding: announce.dropFirst(100), as: UTF8.self) == "/announce?passkey=fixture")
        let announceTransaction: UInt32 = try #require(announce.integer(at: 12))
        response = Data(); for value in [UInt32(1), announceTransaction, 60, 4, 12] { response.appendBE(value) }
        response.append(contentsOf: [127,0,0,1,0x1a,0xe1]); try await server.send(response)
        let result = try await announcing.value
        #expect(result.seeders == 12); #expect(result.leechers == 4)
        #expect(result.peers == [.init(host: "127.0.0.1", port: 6881)])
    }
}


extension TrackerTests {
    @Test func rejectOversizedTrackerInputsBeforeParsing() throws {
        #expect(throws: (any Error).self) { try TrackerClient.decodeCompactPeers(Data(repeating: 0, count: 6 * 5001)) }
        #expect(throws: (any Error).self) { try TrackerClient.decodeUDPResponse(Data(repeating: 0, count: 65536), transactionID: 1) }
        #expect(throws: (any Error).self) { try TrackerClient.decodeHTTPResponse(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)) }
    }
}
