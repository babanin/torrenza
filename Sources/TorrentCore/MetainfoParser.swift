import Foundation
import CryptoKit

public enum MetainfoParser {
    public static func parse(_ data: Data) throws -> TorrentMetainfo {
        let decoded = try Bencode.decodeMetainfo(data)
        guard let root = decoded.value.dictionaryValue, let rawInfo = decoded.info else { throw invalid("Torrent must contain an info dictionary") }
        var tiers: [[URL]] = []
        if let values = root["announce-list"]?.listValue {
            for tier in values.prefix(64) {
                let urls = (tier.listValue ?? []).prefix(64).compactMap { trackerURL($0.stringValue) }
                var seen = Set<URL>()
                let unique = urls.filter { seen.insert($0).inserted }
                if !unique.isEmpty { tiers.append(unique) }
            }
        }
        if tiers.isEmpty, let announce = trackerURL(root["announce"]?.stringValue) { tiers = [[announce]] }
        guard let info = root["info"]?.dictionaryValue else { throw invalid("Info must be a dictionary") }
        return try buildInfo(rawInfo, info: info, trackerTiers: tiers)
    }

    public static func parseInfo(_ data: Data, trackers: [URL]) throws -> TorrentMetainfo {
        guard let info = try Bencode.decode(data).dictionaryValue else { throw invalid("Info must be a dictionary") }
        return try buildInfo(data, info: info, trackerTiers: trackers.prefix(64).compactMap { trackerURL($0.absoluteString).map { [$0] } })
    }

    private static func buildInfo(_ data: Data, info: [String: BencodeValue], trackerTiers: [[URL]]) throws -> TorrentMetainfo {
        guard let pieces = info["pieces"]?.dataValue else {
            if info["meta version"]?.intValue == 2 { throw TorrentError.unsupported("Pure BitTorrent v2 torrents are not supported; use a v1 or hybrid torrent") }
            throw invalid("Missing v1 piece hashes")
        }
        let name = try component(info["name.utf-8"] ?? info["name"], field: "torrent name")
        guard let pieceLength = info["piece length"]?.intValue, pieceLength > 0, pieceLength <= 1_073_741_824 else { throw invalid("Piece length must be between 1 byte and 1 GiB") }
        guard pieces.count.isMultiple(of: 20) else { throw invalid("Invalid SHA-1 piece hash list") }
        guard info["symlink path"] == nil, !(info["attr"]?.stringValue?.contains("l") ?? false) else { throw invalid("Symlink entries are unsupported") }
        let isMultiFile = info["files"] != nil
        guard !(isMultiFile && info["length"] != nil) else { throw invalid("Torrent contains both single-file and multi-file layouts") }
        var files: [TorrentFile] = []
        var total: Int64 = 0
        var paths: [String: (original: String, isFile: Bool)] = [:]
        func appendFile(_ record: [String: BencodeValue], path: [String]) throws {
            guard let length = record["length"]?.intValue, length >= 0 else { throw invalid("File has invalid length") }
            guard record["symlink path"] == nil, !(record["attr"]?.stringValue?.contains("l") ?? false) else { throw invalid("Symlink entries are unsupported") }
            guard path.joined(separator: "/").utf8.count <= 4096 else { throw invalid("File path exceeds size limit") }
            let sum = total.addingReportingOverflow(length)
            guard !sum.overflow else { throw invalid("Total torrent size overflows Int64") }
            let isPadding = record["attr"]?.stringValue?.contains("p") ?? false
            var original = ""
            var normalized = ""
            // Padding is virtual and never materialized; repeated .pad/length paths are valid.
            for (index, part) in path.enumerated() where !isPadding {
                original += "/" + part
                normalized += "/" + part.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let isFile = index == path.count - 1
                if let existing = paths[normalized] {
                    guard existing.original == original, !existing.isFile, !isFile else { throw invalid("File paths collide on a macOS volume") }
                } else { paths[normalized] = (original, isFile) }
            }
            files.append(TorrentFile(index: files.count, path: path, length: length, offset: total, isPadding: isPadding))
            total = sum.partialValue
        }
        if isMultiFile {
            guard let records = info["files"]?.listValue, !records.isEmpty, records.count <= 100_000 else { throw invalid("Invalid file list or more than 100,000 files") }
            for value in records {
                guard let record = value.dictionaryValue, let parts = (record["path.utf-8"] ?? record["path"])?.listValue, !parts.isEmpty, parts.count <= 64 else { throw invalid("Invalid file path") }
                let path = try parts.map { try component($0, field: "file path") }
                try appendFile(record, path: [name] + path)
            }
        } else { try appendFile(info, path: [name]) }
        let expectedPieces = total / pieceLength + (total % pieceLength == 0 ? 0 : 1)
        guard expectedPieces == Int64(pieces.count / 20) else { throw invalid("Piece hash count does not match torrent length") }
        if let privacy = info["private"] { guard let value = privacy.intValue, value == 0 || value == 1 else { throw invalid("Invalid private flag") } }
        let hashes = try PieceHashes(bytes: pieces)
        return TorrentMetainfo(infoHash: Data(Insecure.SHA1.hash(data: data)), rawInfo: data, name: name, pieceLength: Int(pieceLength), pieceHashes: hashes, files: files, trackerTiers: trackerTiers, isPrivate: info["private"]?.intValue == 1, isMultiFile: isMultiFile)
    }

    static func trackerURL(_ text: String?) -> URL? {
        guard let text, text.utf8.count <= 8192, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "udp"].contains(scheme),
              let host = url.host, !host.isEmpty, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!) else { return nil }
        return url
    }
    private static func component(_ value: BencodeValue?, field: String) throws -> String {
        guard let text = value?.stringValue, !text.isEmpty, text != ".", text != "..", text.utf8.count <= 255,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }) else {
            throw invalid("Unsafe or invalid UTF-8 \(field)")
        }
        return text
    }
    private static func invalid(_ text: String) -> TorrentError { .invalidMetainfo(text) }
}
