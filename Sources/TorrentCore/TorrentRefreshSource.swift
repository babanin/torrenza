import Foundation

/// The user-supplied download location, separate from peer announce URLs.
public enum TorrentRefreshSource: Sendable, Codable, Equatable {
    case ruTracker(topicID: String, host: String)
    case direct(URL)

    private enum CodingKeys: String, CodingKey { case ruTracker, direct }
    private enum TopicKeys: String, CodingKey { case topicID, host }
    private enum DirectKeys: String, CodingKey { case value = "_0" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one torrent refresh source"))
        }
        if container.contains(.ruTracker) {
            let values = try container.nestedContainer(keyedBy: TopicKeys.self, forKey: .ruTracker)
            self = try Self.topicSource(topicID: values.decode(String.self, forKey: .topicID), host: values.decode(String.self, forKey: .host))
        } else {
            let values = try container.nestedContainer(keyedBy: DirectKeys.self, forKey: .direct)
            let url = try values.decode(URL.self, forKey: .value)
            _ = try Self(url: url)
            self = .direct(url)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ruTracker(let topicID, let host):
            _ = try Self.topicSource(topicID: topicID, host: host)
            var values = container.nestedContainer(keyedBy: TopicKeys.self, forKey: .ruTracker)
            try values.encode(topicID, forKey: .topicID)
            try values.encode(host, forKey: .host)
        case .direct(let url):
            _ = try Self(url: url)
            var values = container.nestedContainer(keyedBy: DirectKeys.self, forKey: .direct)
            try values.encode(url, forKey: .value)
        }
    }

    public init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 8192,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || (1...65535).contains(components.port!) else {
            throw TorrentError.unsupported("Enter an HTTP or HTTPS torrent download URL or RuTracker topic URL")
        }
        if ["rutracker.org", "rutracker.net"].contains(host) {
            let topicItems = (components.queryItems ?? []).filter { $0.name == "t" }
            guard ["/forum/viewtopic.php", "/forum/dl.php"].contains(components.path),
                  components.port == nil || components.port == (scheme == "https" ? 443 : 80),
                  topicItems.count == 1, let topic = topicItems.first?.value else {
                throw TorrentError.unsupported("Enter a RuTracker topic URL containing a valid topic number")
            }
            self = try Self.topicSource(topicID: topic, host: host)
        } else {
            self = .direct(url)
        }
    }

    private static func topicSource(topicID: String, host: String) throws -> Self {
        guard ["rutracker.org", "rutracker.net"].contains(host.lowercased()),
              !topicID.isEmpty, topicID.utf8.count <= 8192,
              topicID.utf8.allSatisfy({ (48...57).contains($0) }),
              let firstNonzero = topicID.firstIndex(where: { $0 != "0" }) else {
            throw TorrentError.unsupported("Enter a valid RuTracker host and positive topic number")
        }
        return .ruTracker(topicID: String(topicID[firstNonzero...]), host: host.lowercased())
    }

    public var url: URL {
        switch self {
        case .direct(let url): return url
        case .ruTracker(let topicID, let host):
            var components = URLComponents()
            components.scheme = "https"
            // Enum cases are public; an invalid host constructed by a caller must not crash.
            components.host = ["rutracker.org", "rutracker.net"].contains(host.lowercased()) ? host.lowercased() : "rutracker.org"
            components.path = "/forum/viewtopic.php"
            components.queryItems = [URLQueryItem(name: "t", value: topicID)]
            return components.url!
        }
    }
}
