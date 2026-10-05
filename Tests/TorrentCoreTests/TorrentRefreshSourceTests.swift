import Foundation
import Testing
@testable import TorrentCore

struct TorrentRefreshSourceTests {
    private func torrent(_ extras: [String: BencodeValue] = [:]) throws -> TorrentMetainfo {
        var root = extras
        root["info"] = .dictionary([
            "name": .bytes(Data("episode.mkv".utf8)), "length": .integer(4),
            "piece length": .integer(4), "pieces": .bytes(Data(repeating: 7, count: 20))
        ])
        return try MetainfoParser.parse(Bencode.encode(.dictionary(root)))
    }

    @Test func topicAndDownloadURLsNormalizeToHTTPS() throws {
        for input in ["http://rutracker.org/forum/viewtopic.php?t=001234#last", "https://RUTRACKER.ORG/forum/dl.php?t=1234&extra=1"] {
            let source = try TorrentRefreshSource(url: #require(URL(string: input)))
            #expect(source == .ruTracker(topicID: "1234", host: "rutracker.org"))
            #expect(source.url.absoluteString == "https://rutracker.org/forum/viewtopic.php?t=1234")
        }
        #expect(try TorrentRefreshSource(url: #require(URL(string: "https://rutracker.net/forum/dl.php?t=45"))) == .ruTracker(topicID: "45", host: "rutracker.net"))
    }

    @Test func directURLsPreserveTheirDownloadLocation() throws {
        let url = try #require(URL(string: "https://downloads.example.test/latest.torrent?key=abc"))
        let source = try TorrentRefreshSource(url: url)
        #expect(source == .direct(url))
        #expect(source.url == url)
        #expect(try JSONDecoder().decode(TorrentRefreshSource.self, from: JSONEncoder().encode(source)) == source)
    }

    @Test func rejectsUnsafeURLsAndMalformedTopics() throws {
        for input in [
            "file:///tmp/a.torrent", "ftp://example.test/a.torrent", "https://user:password@example.test/a.torrent",
            "https://rutracker.org/forum/viewtopic.php", "https://rutracker.org/forum/viewtopic.php?t=0",
            "https://rutracker.org/forum/viewtopic.php?t=-12", "https://rutracker.org/forum/viewtopic.php?t=12a",
            "https://rutracker.org/forum/viewtopic.php?t=12&t=13", "https://rutracker.org/announce?t=12",
            "https://rutracker.org:8443/forum/viewtopic.php?t=12", "https://example.test:0/a.torrent"
        ] {
            let url = try #require(URL(string: input))
            #expect(throws: TorrentError.self) { try TorrentRefreshSource(url: url) }
        }
    }

    @Test func commentsPreserveOnlyRecognizedTopicLinks() throws {
        let comment = "Downloaded from https://rutracker.org/forum/viewtopic.php?t=1234"
        let metainfo = try torrent(["comment": .bytes(Data(comment.utf8))])
        #expect(metainfo.refreshSource == .ruTracker(topicID: "1234", host: "rutracker.org"))
        #expect(try torrent([
            "comment.utf-8": .bytes(Data("https://rutracker.net/forum/viewtopic.php?t=789".utf8)),
            "comment": .bytes(Data(comment.utf8))
        ]).refreshSource == .ruTracker(topicID: "789", host: "rutracker.net"))
        #expect(try torrent(["comment": .bytes(Data("https://example.test/latest.torrent".utf8))]).refreshSource == nil)
        #expect(try torrent(["announce": .bytes(Data("https://rutracker.org/forum/viewtopic.php?t=1234".utf8))]).refreshSource == nil)
        #expect(try torrent(["comment": .bytes(Data((comment + String(repeating: " ", count: 8192)).utf8))]).refreshSource == nil)
        #expect(try torrent(["comment": .bytes(Data([255]))]).refreshSource == nil)
        #expect(try torrent(["comment": .bytes(Data("https://rutracker.org.evil.test/forum/viewtopic.php?t=1234".utf8))]).refreshSource == nil)
        #expect(try MetainfoParser.parseInfo(metainfo.rawInfo, trackers: metainfo.trackerTiers.flatMap { $0 }).refreshSource == nil)
    }

    @Test func legacyMetainfoDecodesWithoutRefreshSource() throws {
        var metainfo = try torrent()
        metainfo.refreshSource = .ruTracker(topicID: "1234", host: "rutracker.org")
        let data = try JSONEncoder().encode(metainfo)
        #expect(try JSONDecoder().decode(TorrentMetainfo.self, from: data) == metainfo)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "refreshSource")
        let decoded = try JSONDecoder().decode(TorrentMetainfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.refreshSource == nil)
        #expect(decoded.infoHash == metainfo.infoHash)
        #expect(decoded.files == metainfo.files)
    }

    @Test func decodingPreservesWireShapeAndRejectsUnsafeCases() throws {
        let topicJSON = Data(#"{"ruTracker":{"topicID":"001234","host":"RUTRACKER.ORG"}}"#.utf8)
        #expect(try JSONDecoder().decode(TorrentRefreshSource.self, from: topicJSON) == .ruTracker(topicID: "1234", host: "rutracker.org"))
        for invalid in [
            #"{"ruTracker":{"topicID":"0","host":"rutracker.org"}}"#,
            #"{"ruTracker":{"topicID":"1&x=2","host":"rutracker.org"}}"#,
            #"{"ruTracker":{"topicID":"1","host":"rutracker.org.evil.test"}}"#,
            #"{"direct":{"_0":"file:///tmp/private.torrent"}}"#,
            #"{"direct":{"_0":"https://user:password@example.test/a.torrent"}}"#
        ] {
            #expect(throws: TorrentError.self) { try JSONDecoder().decode(TorrentRefreshSource.self, from: Data(invalid.utf8)) }
        }
        let encoded = try JSONEncoder().encode(TorrentRefreshSource.ruTracker(topicID: "1234", host: "rutracker.org"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [String: String]])
        #expect(object == ["ruTracker": ["topicID": "1234", "host": "rutracker.org"]])
        for invalid in [TorrentRefreshSource.ruTracker(topicID: "0", host: "rutracker.org"),
                        .ruTracker(topicID: "1", host: "example.test"),
                        .direct(URL(fileURLWithPath: "/tmp/private.torrent"))] {
            #expect(throws: TorrentError.self) { try JSONEncoder().encode(invalid) }
        }
    }
}
