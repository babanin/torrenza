import Foundation
import Network
import TorrentCore

public struct ExtensionHandshake: Sendable, Equatable {
    public let metadataID: UInt8?
    public let pexID: UInt8?
    public let metadataSize: Int?
}

public struct MetadataMessage: Sendable, Equatable {
    public let type: Int
    public let piece: Int
    public let totalSize: Int?
    public let block: Data
}

/// BEP 10/9/11 payloads; the outer peer-wire extension message byte is supplied by the caller.
public enum PeerExtensions {
    public static let maxMetadataSize = 16 * 1024 * 1024
    public static let metadataBlockSize = 16 * 1024
    public static func extendedHandshake(metadataSize: Int? = nil, allowPEX: Bool = true) -> Data {
        var mapping: [String: BencodeValue] = ["ut_metadata": .integer(1)]
        if allowPEX { mapping["ut_pex"] = .integer(2) }
        var values: [String: BencodeValue] = ["m": .dictionary(mapping), "v": .bytes(Data(ClientIdentity.userAgent.utf8)), "reqq": .integer(32)]
        if let size = metadataSize, (1...maxMetadataSize).contains(size) { values["metadata_size"] = .integer(Int64(size)) }
        return Bencode.encode(.dictionary(values))
    }
    public static func parseHandshake(_ data: Data) throws -> ExtensionHandshake {
        guard data.count <= 64 * 1024, let values = try Bencode.decode(data).dictionaryValue else { throw TorrentError.invalidMessage("Invalid extension handshake") }
        let extensions = values["m"]?.dictionaryValue ?? [:]
        func identifier(_ key: String) throws -> UInt8? {
            guard let value = extensions[key] else { return nil }
            guard let number = value.intValue, (0...255).contains(number) else { throw TorrentError.invalidMessage("Invalid extension identifier") }
            return number == 0 ? nil : UInt8(number)
        }
        var size: Int?
        if let value = values["metadata_size"] {
            guard let number = value.intValue, (1...Int64(maxMetadataSize)).contains(number) else { throw TorrentError.invalidMessage("Metadata exceeds size limit") }
            size = Int(number)
        }
        return try ExtensionHandshake(metadataID: identifier("ut_metadata"), pexID: identifier("ut_pex"), metadataSize: size)
    }
    public static func metadataRequest(piece: Int) -> Data { metadataHeader(type: 0, piece: piece) }
    public static func metadataReject(piece: Int) -> Data { metadataHeader(type: 2, piece: piece) }
    public static func metadataData(piece: Int, totalSize: Int, block: Data) -> Data {
        metadataHeader(type: 1, piece: piece, totalSize: totalSize) + block
    }
    private static func metadataHeader(type: Int, piece: Int, totalSize: Int? = nil) -> Data {
        var values: [String: BencodeValue] = ["msg_type": .integer(Int64(type)), "piece": .integer(Int64(piece))]
        if let totalSize { values["total_size"] = .integer(Int64(totalSize)) }
        return Bencode.encode(.dictionary(values))
    }
    public static func parseMetadata(_ data: Data) throws -> MetadataMessage {
        guard data.count <= metadataBlockSize + 1024 else { throw TorrentError.invalidMessage("Oversized metadata message") }
        let (header, consumed) = try Bencode.decodePrefix(data)
        guard let values = header.dictionaryValue,
              let type = values["msg_type"]?.intValue, (0...2).contains(type),
              let piece = values["piece"]?.intValue, (0..<Int64(maxMetadataSize / metadataBlockSize)).contains(piece) else { throw TorrentError.invalidMessage("Invalid metadata header") }
        let block = Data(data.dropFirst(consumed))
        var size: Int?
        if type == 1 {
            guard let total = values["total_size"]?.intValue, (1...Int64(maxMetadataSize)).contains(total),
                  piece * Int64(metadataBlockSize) < total else { throw TorrentError.invalidMessage("Invalid metadata size or piece") }
            size = Int(total)
            let expected = min(metadataBlockSize, Int(total) - Int(piece) * metadataBlockSize)
            guard block.count == expected else { throw TorrentError.invalidMessage("Incorrect metadata block length") }
        } else if !block.isEmpty { throw TorrentError.invalidMessage("Unexpected metadata payload") }
        return MetadataMessage(type: Int(type), piece: Int(piece), totalSize: size, block: block)
    }
    public static func parsePEX(_ data: Data) throws -> [PeerEndpoint] {
        guard data.count <= 64 * 1024, let values = try Bencode.decode(data).dictionaryValue else { throw TorrentError.invalidMessage("Invalid peer exchange") }
        var result: [PeerEndpoint] = []
        for (key, ipv6) in [("added", false), ("added6", true)] {
            if let value = values[key] {
                guard let compact = value.dataValue else { throw TorrentError.invalidMessage("Invalid compact peer exchange") }
                let endpoints = try CompactAddress.decode(compact, ipv6: ipv6, limit: 200)
                if let flags = values[key + ".f"]?.dataValue, flags.count != endpoints.count { throw TorrentError.invalidMessage("Incorrect peer exchange flags") }
                result += endpoints
            }
        }
        guard result.count <= 200 else { throw TorrentError.invalidMessage("Too many peer exchange entries") }
        return Array(Set(result))
    }
    public static func encodePEX(added: [PeerEndpoint], dropped: [PeerEndpoint] = []) -> Data {
        var values: [String: BencodeValue] = [:]
        let uniqueAdded = Array(Set(added))
        let uniqueDropped = Array(Set(dropped).subtracting(Set(added)))
        for (name, endpoints) in [("added", uniqueAdded), ("dropped", uniqueDropped)] {
            var v4 = Data(), v6 = Data()
            for endpoint in endpoints.prefix(50) {
                if let compact = CompactAddress.encode(endpoint) {
                    if compact.count == 6 { v4.append(compact) } else { v6.append(compact) }
                }
            }
            if !v4.isEmpty { values[name] = .bytes(v4) }
            if !v6.isEmpty { values[name + "6"] = .bytes(v6) }
        }
        if values.isEmpty { values["added"] = .bytes(Data()) }
        return Bencode.encode(.dictionary(values))
    }
}

/// Compact addresses are numeric only: DNS resolution belongs to the transport.
enum CompactAddress {
    static func encode(_ endpoint: PeerEndpoint) -> Data? {
        guard endpoint.port != 0 else { return nil }
        let address: Data
        if let v4 = IPv4Address(endpoint.host) { address = v4.rawValue }
        else if let v6 = IPv6Address(endpoint.host) { address = v6.rawValue }
        else { return nil }
        return address + Data([UInt8(endpoint.port >> 8), UInt8(endpoint.port & 255)])
    }
    static func decode(_ data: Data, ipv6: Bool, limit: Int = 256) throws -> [PeerEndpoint] {
        let stride = ipv6 ? 18 : 6
        guard data.count.isMultiple(of: stride), data.count / stride <= limit else { throw TorrentError.invalidMessage("Invalid compact address length") }
        var result: [PeerEndpoint] = []
        for offset in Swift.stride(from: 0, to: data.count, by: stride) {
            let part = Data(data.dropFirst(offset).prefix(stride))
            let address = Data(part.prefix(stride - 2))
            let host = ipv6 ? IPv6Address(address)?.debugDescription : IPv4Address(address)?.debugDescription
            let port = UInt16(part[stride - 2]) << 8 | UInt16(part[stride - 1])
            if let host, port != 0 { result.append(PeerEndpoint(host: host, port: port)) }
        }
        return result
    }
}
