import Foundation
import CryptoKit
import Testing
@testable import TorrentCore

struct ParsingTests {
    private func bytes(_ text: String) -> BencodeValue { .bytes(Data(text.utf8)) }
    private func info(name: String = "example", length: Int64 = 4, pieceLength: Int64 = 4) -> BencodeValue {
        .dictionary(["name": bytes(name), "length": .integer(length), "piece length": .integer(pieceLength), "pieces": .bytes(Data(repeating: 7, count: length == 0 ? 0 : 20))])
    }
    @Test func bencodeRoundTripAndPrefix() throws {
        let original = BencodeValue.dictionary(["i": .integer(Int64.min), "l": .list([bytes("hello"), .integer(42)]), "raw": .bytes(Data([0, 255, 128]))])
        let encoded = Bencode.encode(original)
        #expect(try Bencode.decode(encoded) == original)
        let prefix = try Bencode.decodePrefix(encoded + Data([0, 1, 2]))
        #expect(prefix.value == original)
        #expect(prefix.consumed == encoded.count)
        #expect(throws: TorrentError.self) { try Bencode.decode(encoded + Data([0])) }
    }
    @Test func rejectsMalformedAndComplexBencode() {
        for text in ["", "i01e", "i-0e", "i+1e", "i9223372036854775808e", "01:a", "4:abc", "d1:ai1e1:ai2ee", "lejunk", "i1", "d1:a", "-1:x"] {
            #expect(throws: TorrentError.self) { try Bencode.decode(Data(text.utf8)) }
        }
        #expect(throws: TorrentError.self) { try Bencode.decode(Data((String(repeating: "l", count: 66) + String(repeating: "e", count: 66)).utf8)) }
        #expect(throws: TorrentError.self) { try Bencode.decode(Data(repeating: 0, count: Bencode.maximumBytes + 1)) }
    }
    @Test func limitsNodeAmplificationAndPreservesBinaryKeys() throws {
        // Tiny on-wire empty values must not amplify into an unbounded object graph.
        var excessive = Data([108])
        excessive.append(Data(String(repeating: "0:", count: Bencode.maximumNodes).utf8))
        excessive.append(101)
        #expect(throws: TorrentError.self) { try Bencode.decode(excessive) }
        let binaryKeys = Data([100, 49, 58, 255, 49, 58, 120, 49, 58, 254, 49, 58, 121, 101])
        let parsed = try Bencode.decode(binaryKeys)
        #expect(parsed.dictionaryValue?.count == 2)
        #expect(try Bencode.decode(Bencode.encode(parsed)) == parsed)
        let duplicateBinary = Data([100, 49, 58, 255, 49, 58, 120, 49, 58, 255, 49, 58, 121, 101])
        #expect(throws: TorrentError.self) { try Bencode.decode(duplicateBinary) }
    }
    @Test func exactRawInfoHash() throws {
        // Deliberately noncanonical dictionary order. Parsing must not silently change the info hash.
        let raw = Data("d4:name1:A6:lengthi4e12:piece lengthi4e6:pieces20:abcdefghijklmnopqrste".utf8)
        var torrent = Data("d4:info".utf8)
        torrent.append(raw); torrent.append(101)
        let parsed = try MetainfoParser.parse(torrent)
        #expect(parsed.rawInfo == raw)
        #expect(parsed.infoHash == Data(Insecure.SHA1.hash(data: raw)))
        #expect(parsed.files.first?.path == ["A"])
        #expect(parsed.totalLength == 4)
    }
    @Test func singleAndEmptyFile() throws {
        let single = try MetainfoParser.parseInfo(Bencode.encode(info()), trackers: [])
        #expect(single.files.count == 1)
        #expect(single.pieceLength == 4)
        #expect(single.files[0].offset == 0)
        let empty = try MetainfoParser.parseInfo(Bencode.encode(info(length: 0)), trackers: [])
        #expect(empty.pieceHashes.isEmpty)
    }
    @Test func rejectsUnsafePathsAndHashMismatch() {
        for name in ["../oops", "..", "/tmp", "a/b", "a\\b", "a:b", "nul\0", ""] {
            #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(info(name: name)), trackers: []) }
        }
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(info(length: 9)), trackers: []) }
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(info(pieceLength: 0)), trackers: []) }
    }
    private func multifile(_ paths: [[String]], attrs: [String] = []) -> BencodeValue {
        let records: [BencodeValue] = paths.enumerated().map { index, path in
            var record: [String: BencodeValue] = ["path": .list(path.map(bytes)), "length": .integer(2)]
            if index < attrs.count { record["attr"] = bytes(attrs[index]) }
            return .dictionary(record)
        }
        return .dictionary(["name": bytes("root"), "files": .list(records), "piece length": .integer(4), "pieces": .bytes(Data(repeating: 1, count: ((paths.count + 1) / 2) * 20))])
    }
    @Test func multifileOffsetsAndPadding() throws {
        let parsed = try MetainfoParser.parseInfo(Bencode.encode(multifile([["dir", "a"], [".pad", "2"], ["b"]], attrs: ["", "p", ""])), trackers: [])
        #expect(parsed.isMultiFile)
        #expect(parsed.files.map(\.offset) == [0, 2, 4])
        #expect(parsed.files[0].path == ["root", "dir", "a"])
        #expect(parsed.files[1].isPadding)
        #expect(parsed.lengthOfPiece(1) == 2)
    }
    @Test func allowsRepeatedVirtualPaddingPaths() throws {
        let parsed = try MetainfoParser.parseInfo(Bencode.encode(multifile([["a"], [".pad", "2"], ["b"], [".pad", "2"]], attrs: ["", "p", "", "p"])), trackers: [])
        #expect(parsed.files.filter(\.isPadding).count == 2)
    }
    @Test func rejectsCollisionsAndSymlinks() {
        for paths in [[["A"], ["a"]], [["é"], ["e\u{301}"]], [["a"], ["a", "b"]], [["a", "b"], ["a"]], [["Dir", "a"], ["dir", "b"]]] {
            #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(multifile(paths)), trackers: []) }
        }
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(multifile([["a"]], attrs: ["l"])), trackers: []) }
    }
    @Test func rejectsOverflowAndInvalidUTF8() {
        var fields = multifile([["a"], ["b"]]).dictionaryValue!
        fields["files"] = .list([.dictionary(["path": .list([bytes("a")]), "length": .integer(Int64.max)]), .dictionary(["path": .list([bytes("b")]), "length": .integer(1)])])
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(.dictionary(fields)), trackers: []) }
        fields = info().dictionaryValue!
        fields["name"] = .bytes(Data([255]))
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(.dictionary(fields)), trackers: []) }
    }
    @Test func acceptsHybridBinaryPieceLayersAndRejectsPureV2() throws {
        let rawInfo = Bencode.encode(info())
        var payload = Data("d4:info".utf8); payload.append(rawInfo)
        payload.append(contentsOf: "12:piece layersd1:".utf8); payload.append(255)
        payload.append(contentsOf: "1:xee".utf8)
        #expect(try MetainfoParser.parse(payload).rawInfo == rawInfo)
        let decoded = try Bencode.decode(payload)
        #expect(try Bencode.decode(Bencode.encode(decoded)) == decoded)
        #expect(throws: TorrentError.self) { try MetainfoParser.parseInfo(Bencode.encode(.dictionary(["meta version": .integer(2)])), trackers: []) }
    }
    @Test func trackerTiersAndPrivateFlag() throws {
        var fields = info().dictionaryValue!
        fields["private"] = .integer(1)
        let data = Bencode.encode(.dictionary(["info": .dictionary(fields), "announce-list": .list([.list([bytes("https://tracker.test/announce"), bytes("https://tracker.test/announce")]), .list([bytes("file:///etc/passwd"), bytes("udp://tracker.test:6969")])])]))
        let parsed = try MetainfoParser.parse(data)
        #expect(parsed.isPrivate)
        #expect(parsed.trackerTiers.map(\.count) == [1, 1])
    }
    @Test func magnetsSupportHexAndBase32AndPeers() throws {
        let hex = String(repeating: "00", count: 20)
        let parsed = try MagnetParser.parse(URL(string: "magnet:?xt=urn:btih:\(hex)&dn=Test%20Torrent&tr=https%3A%2F%2Ftracker.test%2Fa&x.pe=127.0.0.1:6881&x.pe=%5B::1%5D:6882")!)
        #expect(parsed.infoHash == Data(repeating: 0, count: 20))
        #expect(parsed.displayName == "Test Torrent")
        #expect(parsed.trackers.count == 1)
        #expect(parsed.peers == [PeerEndpoint(host: "127.0.0.1", port: 6881), PeerEndpoint(host: "::1", port: 6882)])
        #expect(try MagnetParser.parse(URL(string: "magnet:?xt=urn:btih:\(String(repeating: "A", count: 32))")!).infoHash == parsed.infoHash)
        #expect(try MagnetParser.parse(URL(string: "magnet:?xt=urn:btih:\(String(repeating: "7", count: 32))")!).infoHash == Data(repeating: 255, count: 20))
        for text in ["https://example.test", "magnet:?xt=urn:btih:bad", "magnet:?xt=urn:btmh:1220ffff", "magnet:?xt=urn:btih:\(hex)&xt=urn:btih:\(String(repeating: "11", count: 20))"] {
            #expect(throws: TorrentError.self) { try MagnetParser.parse(URL(string: text)!) }
        }
    }
}
