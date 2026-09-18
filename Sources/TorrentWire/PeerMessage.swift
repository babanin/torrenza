import Foundation
import TorrentCore

public struct PeerHandshake: Sendable, Equatable {
    public let infoHash: Data
    public let peerID: Data
    public let supportsExtensions: Bool
    public let supportsDHT: Bool
    public init(infoHash: Data, peerID: Data, supportsExtensions: Bool = true, supportsDHT: Bool = true) {
        self.infoHash = infoHash; self.peerID = peerID; self.supportsExtensions = supportsExtensions; self.supportsDHT = supportsDHT
    }
    public func encode() throws -> Data {
        guard infoHash.count == 20, peerID.count == 20 else { throw TorrentError.invalidMessage("Handshake identifiers must be 20 bytes") }
        var result = Data([19]); result.append(Data("BitTorrent protocol".utf8))
        var reserved = [UInt8](repeating: 0, count: 8)
        if supportsExtensions { reserved[5] |= 0x10 }; if supportsDHT { reserved[7] |= 1 }
        result.append(contentsOf: reserved); result.append(infoHash); result.append(peerID); return result
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count == 68 else { throw TorrentError.invalidMessage("Invalid handshake size") }
        let b = [UInt8](data)
        guard b.count == 68, b[0] == 19, Data(b[1..<20]) == Data("BitTorrent protocol".utf8) else { throw TorrentError.invalidMessage("Invalid BitTorrent handshake") }
        return .init(infoHash: Data(b[28..<48]), peerID: Data(b[48..<68]), supportsExtensions: b[25] & 0x10 != 0, supportsDHT: b[27] & 1 != 0)
    }
}

public enum PeerMessage: Sendable, Equatable {
    case choke, unchoke, interested, notInterested, have(Int), bitfield(Data)
    case request(index: Int, begin: Int, length: Int)
    case piece(index: Int, begin: Int, block: Data)
    case cancel(index: Int, begin: Int, length: Int)
    case port(UInt16), extended(id: UInt8, payload: Data), keepAlive
    public static let maximumFrameLength = 128 * 1024 + 9
    public static let maximumBlockLength = 128 * 1024

    /// Includes the four-byte network-order frame length.
    public func encode() throws -> Data {
        var body = Data()
        func word(_ value: Int) throws { guard value >= 0, value <= Int(UInt32.max) else { throw TorrentError.invalidMessage("Out-of-range peer field") }; body.appendBE(UInt32(value)) }
        switch self {
        case .keepAlive: break
        case .choke: body.append(0)
        case .unchoke: body.append(1)
        case .interested: body.append(2)
        case .notInterested: body.append(3)
        case .have(let index): body.append(4); try word(index)
        case .bitfield(let bits):
            guard bits.count < Self.maximumFrameLength else { throw TorrentError.invalidMessage("Bitfield exceeds frame limit") }
            body.append(5); body.append(bits)
        case .request(let index, let begin, let length), .cancel(let index, let begin, let length):
            guard (1...Self.maximumBlockLength).contains(length) else { throw TorrentError.invalidMessage("Invalid request length") }
            if case .request = self { body.append(6) } else { body.append(8) }
            try word(index); try word(begin); try word(length)
        case .piece(let index, let begin, let block):
            guard !block.isEmpty, block.count <= Self.maximumBlockLength else { throw TorrentError.invalidMessage("Invalid piece block length") }
            body.append(7); try word(index); try word(begin); body.append(block)
        case .port(let port): body.append(9); body.appendBE(port)
        case .extended(let id, let payload):
            guard payload.count <= Self.maximumFrameLength - 2 else { throw TorrentError.invalidMessage("Extension exceeds frame limit") }
            body.append(20); body.append(id); body.append(payload)
        }
        guard body.count <= Self.maximumFrameLength else { throw TorrentError.invalidMessage("Peer message exceeds frame limit") }
        var frame = Data(); frame.appendBE(UInt32(body.count)); frame.append(body); return frame
    }
    public static func decode(_ frame: Data) throws -> Self {
        guard frame.count >= 4, frame.count <= maximumFrameLength + 4 else { throw TorrentError.invalidMessage("Invalid peer frame length") }
        let b = [UInt8](frame)
        guard b.count >= 4, let length: UInt32 = b.integer(at: 0), length <= maximumFrameLength, Int(length) == b.count - 4 else { throw TorrentError.invalidMessage("Invalid peer frame length") }
        return try decodePayload(Data(b.dropFirst(4)))
    }
    public static func decodePayload(_ payload: Data) throws -> Self {
        guard payload.count <= maximumFrameLength else { throw TorrentError.invalidMessage("Peer message exceeds frame limit") }
        let b = [UInt8](payload)
        if b.isEmpty { return .keepAlive }
        func exact(_ count: Int) throws { guard b.count == count else { throw TorrentError.invalidMessage("Invalid peer message size") } }
        func word(_ offset: Int) throws -> Int { guard let result: UInt32 = b.integer(at: offset) else { throw TorrentError.invalidMessage("Truncated peer field") }; return Int(result) }
        switch b[0] {
        case 0: try exact(1); return .choke
        case 1: try exact(1); return .unchoke
        case 2: try exact(1); return .interested
        case 3: try exact(1); return .notInterested
        case 4: try exact(5); return .have(try word(1))
        case 5: return .bitfield(Data(b.dropFirst()))
        case 6, 8:
            try exact(13); let index = try word(1), begin = try word(5), length = try word(9)
            guard (1...maximumBlockLength).contains(length) else { throw TorrentError.invalidMessage("Invalid peer block length") }
            return b[0] == 6 ? .request(index: index, begin: begin, length: length) : .cancel(index: index, begin: begin, length: length)
        case 7:
            guard b.count > 9, b.count - 9 <= maximumBlockLength else { throw TorrentError.invalidMessage("Invalid piece block") }
            return .piece(index: try word(1), begin: try word(5), block: Data(b.dropFirst(9)))
        case 9: try exact(3); return .port(UInt16(b[1]) << 8 | UInt16(b[2]))
        case 20:
            guard b.count >= 2 else { throw TorrentError.invalidMessage("Truncated extension message") }
            return .extended(id: b[1], payload: Data(b.dropFirst(2)))
        default: throw TorrentError.invalidMessage("Unsupported peer message \(b[0])")
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var big = value.bigEndian; Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) } }
}
extension Array where Element == UInt8 {
    func integer<T: FixedWidthInteger>(at index: Int) -> T? {
        let count = MemoryLayout<T>.size
        guard index >= 0, index <= self.count, count <= self.count - index else { return nil }
        var value: T = 0; for byte in self[index..<(index + count)] { value = (value << 8) | T(byte) }; return value
    }
}
