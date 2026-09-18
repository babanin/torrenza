import Foundation
import Testing
import Network
import TorrentCore
@testable import TorrentWire

struct PeerTests {
    @Test func messagesRoundTrip() throws {
        let messages: [PeerMessage] = [.keepAlive, .choke, .unchoke, .interested, .notInterested, .have(65537), .bitfield(Data([0x80, 0x7f])), .request(index: 7, begin: 16_384, length: 16_384), .piece(index: 5, begin: 9, block: Data([0, 1, 255])), .cancel(index: 2, begin: 0, length: 16384), .port(6881), .extended(id: 2, payload: Data("d1:ai1ee".utf8))]
        for message in messages { #expect(try PeerMessage.decode(message.encode()) == message) }
    }
    @Test func handshakeRoundTripAndBits() throws {
        let handshake = PeerHandshake(infoHash: Data(repeating: 9, count: 20), peerID: Data(repeating: 7, count: 20))
        let encoded = try handshake.encode()
        #expect(encoded.count == 68); #expect(encoded[25] == 0x10); #expect(encoded[27] == 1)
        #expect(try PeerHandshake.decode(encoded) == handshake)
        #expect(throws: (any Error).self) { try PeerHandshake.decode(encoded.dropLast()) }
        #expect(throws: (any Error).self) { try PeerHandshake(infoHash: Data(), peerID: Data()).encode() }
    }
    @Test func malformedFramesRejected() throws {
        for frame in [Data(), Data([0,0,0,1]), Data([0,0,0,2,0,0]), Data([0,0,0,1,255]), Data([0,0,0,1,20]), Data([255,255,255,255])] {
            #expect(throws: (any Error).self) { try PeerMessage.decode(frame) }
        }
        #expect(throws: (any Error).self) { try PeerMessage.request(index: -1, begin: 0, length: 1).encode() }
        #expect(throws: (any Error).self) { try PeerMessage.request(index: 0, begin: 0, length: 0).encode() }
        #expect(throws: (any Error).self) { try PeerMessage.piece(index: 0, begin: 0, block: Data(repeating: 0, count: 131073)).encode() }
        #expect(throws: (any Error).self) { try PeerMessage.bitfield(Data(repeating: 0, count: PeerMessage.maximumFrameLength)).encode() }
    }
    @Test func slicedFramesDecodeWithoutAlignmentAssumptions() throws {
        let message = PeerMessage.request(index: 0x12345678, begin: 16384, length: 16384)
        var data = Data([99]); data.append(try message.encode())
        #expect(try PeerMessage.decode(data.dropFirst()) == message)
    }
}


/// Loopback fixtures exercise Network.framework framing, cancellation and listener handshakes.
final class WireTestListener: @unchecked Sendable {
    let listener: NWListener
    let incoming: AsyncStream<NWConnection>
    init(udp: Bool = false) throws {
        listener = try NWListener(using: udp ? .udp : .tcp, on: .any)
        let stream = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        incoming = stream.stream
        listener.newConnectionHandler = { stream.continuation.yield($0) }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: TorrentError.network("Missing listener port")) }
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "wire.test.listener"))
        }
    }
    func close() { listener.cancel() }
}

extension PeerTests {
    @Test(.timeLimit(.minutes(1))) func loopbackHandshakeAndFrames() async throws {
        let listener = try WireTestListener(); defer { listener.close() }
        let port = try await listener.start()
        let hash = Data(repeating: 42, count: 20), clientID = Data(repeating: 1, count: 20), serverID = Data(repeating: 2, count: 20)
        let client = try PeerConnection(endpoint: .init(host: "127.0.0.1", port: port))
        let connecting = Task { try await client.connect(infoHash: hash, peerID: clientID, supportsDHT: false) }
        var incoming = listener.incoming.makeAsyncIterator()
        let server = PeerConnection(connection: try #require(await incoming.next()))
        let clientHandshake = try await server.receiveHandshake()
        #expect(clientHandshake.infoHash == hash); #expect(clientHandshake.peerID == clientID); #expect(!clientHandshake.supportsDHT)
        try await server.sendHandshake(infoHash: hash, peerID: serverID)
        #expect(try await connecting.value.peerID == serverID)
        try await client.send(.request(index: 12, begin: 16384, length: 16384))
        #expect(try await server.receive() == .request(index: 12, begin: 16384, length: 16384))
        let block = Data(repeating: 99, count: 16384)
        try await server.send(.piece(index: 12, begin: 16384, block: block))
        #expect(try await client.receive() == .piece(index: 12, begin: 16384, block: block))
        await client.close(); await server.close()
    }
    @Test(.timeLimit(.minutes(1))) func transportTimeoutAndCancellation() async throws {
        for cancel in [false, true] {
            let listener = try WireTestListener(); defer { listener.close() }
            let port = try await listener.start()
            let client = try NetworkTransport(endpoint: .init(host: "127.0.0.1", port: port))
            try await client.start(); defer { client.close() }
            var incoming = listener.incoming.makeAsyncIterator()
            let server = NetworkTransport(connection: try #require(await incoming.next()))
            try await server.start(); defer { server.close() }
            let read = Task { try await client.receiveExactly(1, timeout: cancel ? 5 : 0.03) }
            if cancel { read.cancel() }
            do { _ = try await read.value; Issue.record("Read unexpectedly succeeded") }
            catch { if cancel { #expect(error is CancellationError) } }
        }
    }
}

extension PeerTests {
    @Test func oversizedPublicDecodersAndInvalidTimeouts() async throws {
        let oversized = Data(repeating: 0, count: PeerMessage.maximumFrameLength + 5)
        #expect(throws: (any Error).self) { try PeerHandshake.decode(oversized) }
        #expect(throws: (any Error).self) { try PeerMessage.decode(oversized) }
        #expect(throws: (any Error).self) { try PeerMessage.decodePayload(oversized) }
        for timeout in [Double.nan, .infinity, -.infinity, -1, 0, 3601] {
            let transport = try NetworkTransport(endpoint: .init(host: "127.0.0.1", port: 1))
            do { _ = try await transport.receiveExactly(0, timeout: timeout); Issue.record("Invalid timeout accepted") }
            catch { #expect(error is TorrentError) }
            do { try await transport.start(timeout: timeout); Issue.record("Invalid start timeout accepted") }
            catch { #expect(error is TorrentError) }
            transport.close()
        }
    }
    @Test(.timeLimit(.minutes(1))) func reservedFrameCapRejectsHeaderWithoutWaitingForPayload() async throws {
        let listener = try WireTestListener(); defer { listener.close() }
        let port = try await listener.start()
        let transport = try NetworkTransport(endpoint: .init(host: "127.0.0.1", port: port))
        try await transport.start(); defer { transport.close() }
        var incoming = listener.incoming.makeAsyncIterator()
        let receiver = PeerConnection(connection: try #require(await incoming.next()), maximumFrameLength: 65536)
        let hash = Data(repeating: 1, count: 20), peerID = Data(repeating: 2, count: 20)
        try await transport.send(PeerHandshake(infoHash: hash, peerID: peerID).encode())
        _ = try await receiver.receiveHandshake()
        await receiver.setMaximumFrameLength(32768)
        var oversizedHeader = Data(); oversizedHeader.appendBE(UInt32(32769))
        try await transport.send(oversizedHeader)
        // No payload is sent: the receiver must reject just the four-byte length.
        do { _ = try await receiver.receive(); Issue.record("Oversized peer frame accepted") }
        catch { #expect(error is TorrentError) }
        await receiver.close()
    }
    @Test(.timeLimit(.minutes(1))) func fragmentedReadsShareAbsoluteDeadline() async throws {
        let listener = try WireTestListener(); defer { listener.close() }
        let port = try await listener.start()
        let client = try NetworkTransport(endpoint: .init(host: "127.0.0.1", port: port))
        try await client.start(); defer { client.close() }
        var incoming = listener.incoming.makeAsyncIterator()
        let server = NetworkTransport(connection: try #require(await incoming.next()))
        try await server.start(); defer { server.close() }
        let sender = Task {
            for _ in 0..<20 {
                try await server.send(Data([1]))
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.receiveExactly(20, timeout: 0.07); Issue.record("Trickle exceeded deadline") }
        catch { #expect(ProcessInfo.processInfo.systemUptime - start < 0.3) }
        sender.cancel(); _ = try? await sender.value
    }
}
