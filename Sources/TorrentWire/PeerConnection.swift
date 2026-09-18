import Foundation
import Network
import TorrentCore

public actor PeerConnection {
    private let transport: NetworkTransport
    private var started = false
    private var reading = false
    private var maximumFrameLength: Int
    public init(endpoint: PeerEndpoint, maximumFrameLength: Int = PeerMessage.maximumFrameLength) throws {
        transport = try NetworkTransport(endpoint: endpoint)
        self.maximumFrameLength = min(PeerMessage.maximumFrameLength, max(1, maximumFrameLength))
    }
    public init(connection: NWConnection, maximumFrameLength: Int = PeerMessage.maximumFrameLength) {
        transport = NetworkTransport(connection: connection)
        self.maximumFrameLength = min(PeerMessage.maximumFrameLength, max(1, maximumFrameLength))
    }
    /// The engine reserves receive scratch space before setting this limit and starting its receive loop.
    public func setMaximumFrameLength(_ cap: Int) {
        maximumFrameLength = min(PeerMessage.maximumFrameLength, max(1, cap))
    }
    private func start() async throws { if !started { started = true; try await transport.start() } }
    public func connect(infoHash: Data, peerID: Data, supportsDHT: Bool = true) async throws -> PeerHandshake {
        try await start()
        try await sendHandshake(infoHash: infoHash, peerID: peerID, supportsDHT: supportsDHT)
        let handshake = try await receiveHandshake()
        guard handshake.infoHash == infoHash else { transport.close(); throw TorrentError.invalidMessage("Peer answered with a different info hash") }
        return handshake
    }
    public func sendHandshake(infoHash: Data, peerID: Data, supportsDHT: Bool = true) async throws {
        try await start(); try await transport.send(PeerHandshake(infoHash: infoHash, peerID: peerID, supportsDHT: supportsDHT).encode())
    }
    public func receiveHandshake() async throws -> PeerHandshake {
        guard !reading else { throw TorrentError.network("Concurrent peer reads are not supported") }; reading = true; defer { reading = false }
        try await start(); return try PeerHandshake.decode(await transport.receiveExactly(68, timeout: 15))
    }
    public func send(_ message: PeerMessage) async throws { try await transport.send(message.encode()) }
    public func receive() async throws -> PeerMessage {
        guard !reading else { throw TorrentError.network("Concurrent peer reads are not supported") }; reading = true; defer { reading = false }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        let header = [UInt8](try await transport.receiveExactly(4))
        guard let length: UInt32 = header.integer(at: 0), length <= maximumFrameLength else {
            transport.close(); throw TorrentError.invalidMessage("Peer frame exceeds reserved limit")
        }
        let remainingTime = deadline - ProcessInfo.processInfo.systemUptime
        guard remainingTime > 0 else { transport.close(); throw TorrentError.network("Peer frame timed out") }
        return try PeerMessage.decodePayload(await transport.receiveExactly(Int(length), timeout: remainingTime))
    }
    public func close() { transport.close() }
}
