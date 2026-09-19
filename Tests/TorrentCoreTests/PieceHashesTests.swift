import Foundation
import Testing
@testable import TorrentCore

struct PieceHashesTests {
    @Test func legacyJSONPreservesEveryHashAndEncoding() throws {
        let hashes = (0..<4_096).map { index in
            Data((0..<20).map { UInt8(truncatingIfNeeded: index + $0) })
        }
        let legacy = try JSONEncoder().encode(hashes)
        let decoded = try JSONDecoder().decode(PieceHashes.self, from: legacy)
        #expect(decoded.isValid)
        #expect(decoded.count == hashes.count)
        #expect(Array(decoded) == hashes)
        #expect(try JSONEncoder().encode(decoded) == legacy)
        #expect(decoded[17..<20].map { $0 } == Array(hashes[17..<20]))
        #expect(decoded.index(before: decoded.endIndex) == 4_095)
    }

    @Test func packedBytesSupportNonzeroDataIndices() throws {
        let first = Data(repeating: 11, count: 20)
        let second = Data(repeating: 22, count: 20)
        let prefixed = Data(repeating: 99, count: 7) + first + second
        let hashes = try PieceHashes(bytes: prefixed[7...])
        #expect(hashes.startIndex == 0)
        #expect(hashes.endIndex == 2)
        #expect(hashes[0] == first)
        #expect(hashes[1] == second)
        #expect(hashes == PieceHashes([first, second]))
    }

    @Test func rejectsMalformedPersistedHashes() throws {
        for length in [0, 1, 19, 21, 40] {
            let legacy = try JSONEncoder().encode([Data(repeating: 1, count: length)])
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(PieceHashes.self, from: legacy)
            }
        }
        #expect(throws: TorrentError.self) { try PieceHashes(bytes: Data(repeating: 1, count: 21)) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PieceHashes.self, from: Data("[\"invalid base64!\"]".utf8))
        }
    }

    @Test func emptyHashesAndInvalidLegacyModelsRemainDistinguishable() throws {
        let empty = try JSONDecoder().decode(PieceHashes.self, from: Data("[]".utf8))
        #expect(empty.isEmpty)
        #expect(empty.isValid)
        #expect(empty == PieceHashes([]))
        #expect(try JSONEncoder().encode(empty) == Data("[]".utf8))
        // Legacy model construction remains nonthrowing, allowing engine/storage
        // validation to reject malformed caller input without a process crash.
        let invalid = PieceHashes([Data(repeating: 1, count: 19)])
        #expect(!invalid.isValid)
        #expect(invalid.count == 1)
        #expect(invalid[0].count == 19)
    }

    @Test func metainfoUsesCompatiblePersistedRepresentation() throws {
        let first = Data(repeating: 11, count: 20)
        let second = Data(repeating: 22, count: 20)
        let raw = Bencode.encode(.dictionary([
            "name": .bytes(Data("test".utf8)), "length": .integer(7),
            "piece length": .integer(4), "pieces": .bytes(first + second)
        ]))
        let meta = try MetainfoParser.parseInfo(raw, trackers: [])
        #expect(meta.pieceHashes[0] == first)
        #expect(meta.pieceHashes[1] == second)
        #expect(meta.rawInfo == raw)
        let encoded = try JSONEncoder().encode(meta)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["pieceHashes"] as? [String] == [first.base64EncodedString(), second.base64EncodedString()])
        #expect(try JSONDecoder().decode(TorrentMetainfo.self, from: encoded) == meta)
        var legacy = object
        legacy["pieceHashes"] = [first.base64EncodedString(), second.base64EncodedString()]
        #expect(try JSONDecoder().decode(TorrentMetainfo.self, from: JSONSerialization.data(withJSONObject: legacy)) == meta)
        legacy["pieceHashes"] = [Data(repeating: 0, count: 19).base64EncodedString()]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TorrentMetainfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }
}
