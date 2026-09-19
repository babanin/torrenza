import Foundation

/// SHA-1 hashes share one allocation instead of retaining a Data allocation per piece.
/// The persisted representation remains the original array of base64 strings.
public struct PieceHashes: RandomAccessCollection, Sendable, Codable, Equatable {
    public typealias Index = Int
    public typealias Element = Data

    private enum Storage: Sendable, Equatable {
        case packed(Data)
        // Preserve validation of malformed models passed to the nonthrowing legacy
        // initializer. Parsed and decoded metadata never use this representation.
        case invalid([Data])
    }
    private let storage: Storage

    public init(_ hashes: [Data]) {
        guard hashes.allSatisfy({ $0.count == 20 }) else {
            storage = .invalid(hashes)
            return
        }
        var bytes = Data(capacity: hashes.count * 20)
        for hash in hashes { bytes.append(hash) }
        storage = .packed(bytes)
    }

    public init(bytes: Data) throws {
        guard bytes.count.isMultiple(of: 20) else {
            throw TorrentError.invalidMetainfo("Invalid SHA-1 piece hash list")
        }
        storage = .packed(bytes)
    }

    public var isValid: Bool {
        if case .packed = storage { return true }
        return false
    }
    public var startIndex: Int { 0 }
    public var endIndex: Int {
        switch storage {
        case .packed(let bytes): bytes.count / 20
        case .invalid(let hashes): hashes.count
        }
    }
    public func index(after index: Int) -> Int { index + 1 }
    public func index(before index: Int) -> Int { index - 1 }
    public subscript(index: Int) -> Data {
        precondition(indices.contains(index), "Piece hash index out of bounds")
        switch storage {
        case .packed(let bytes):
            let start = bytes.startIndex + index * 20
            return bytes.subdata(in: start..<(start + 20))
        case .invalid(let hashes): return hashes[index]
        }
    }

    public init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        var bytes = Data()
        if let count = values.count, count <= Int.max / 20 {
            bytes.reserveCapacity(count * 20)
        }
        while !values.isAtEnd {
            let hash = try values.decode(Data.self)
            guard hash.count == 20 else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "A SHA-1 piece hash must contain 20 bytes")
            }
            bytes.append(hash)
        }
        storage = .packed(bytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        for hash in self { try values.encode(hash) }
    }
}
