import Foundation

public enum MagnetParser {
    public static func parse(_ url: URL) throws -> MagnetLink {
        guard url.absoluteString.utf8.count <= 64 * 1024, url.scheme?.lowercased() == "magnet",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems,
              items.count <= 256 else { throw TorrentError.invalidMetainfo("Invalid or oversized magnet link") }
        var hash: Data?
        var displayName: String?
        var trackers: [URL] = []
        var peers: [PeerEndpoint] = []
        for item in items {
            guard let value = item.value else { continue }
            switch item.name.lowercased() {
            case "xt" where value.lowercased().hasPrefix("urn:btih:"):
                let text = String(value.dropFirst(9))
                let decoded = text.count == 40 ? Data(hex: text) : decodeBase32(text)
                guard let decoded, decoded.count == 20 else { throw TorrentError.invalidMetainfo("Invalid magnet v1 info hash") }
                guard hash == nil || hash == decoded else { throw TorrentError.invalidMetainfo("Magnet contains conflicting info hashes") }
                hash = decoded
            case "dn": if displayName == nil { displayName = String(value.prefix(1024)) }
            case "tr":
                if trackers.count < 64, let tracker = MetainfoParser.trackerURL(value), !trackers.contains(tracker) { trackers.append(tracker) }
            case "x.pe":
                if peers.count < 64, let peer = peer(value), !peers.contains(peer) { peers.append(peer) }
            default: break
            }
        }
        guard let hash else { throw TorrentError.unsupported("Magnet must contain a BitTorrent v1 info hash (urn:btih)") }
        return MagnetLink(infoHash: hash, displayName: displayName, trackers: trackers, peers: peers)
    }

    private static func decodeBase32(_ text: String) -> Data? {
        guard text.utf8.count == 32 else { return nil }
        var output = Data()
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in text.uppercased().utf8 {
            let value: UInt32
            switch byte { case 65...90: value = UInt32(byte - 65); case 50...55: value = UInt32(byte - 50 + 26); default: return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 { bits -= 8; output.append(UInt8((accumulator >> bits) & 255)) }
        }
        return output
    }
    private static func peer(_ text: String) -> PeerEndpoint? {
        guard let url = URLComponents(string: "tcp://" + text), let host = url.host, !host.isEmpty,
              let port = url.port, port > 0, port <= 65535, url.path.isEmpty, url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil else { return nil }
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return PeerEndpoint(host: unbracketed, port: UInt16(port))
    }
}
