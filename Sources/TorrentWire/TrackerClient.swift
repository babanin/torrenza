import Foundation
import Network
import Darwin
import TorrentCore

public enum TrackerEvent: UInt32, Sendable { case none = 0, completed = 1, started = 2, stopped = 3 }
public struct TrackerRequest: Sendable {
    public var infoHash: Data
    public var peerID: Data
    public var port: UInt16
    public var uploaded: Int64
    public var downloaded: Int64
    public var left: Int64
    public var event: TrackerEvent
    public var numWant: Int
    public init(infoHash: Data, peerID: Data, port: UInt16, uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64, event: TrackerEvent = .none, numWant: Int = 50) {
        self.infoHash = infoHash; self.peerID = peerID; self.port = port; self.uploaded = uploaded; self.downloaded = downloaded; self.left = left; self.event = event; self.numWant = numWant
    }
    func validate() throws {
        guard infoHash.count == 20, peerID.count == 20, port > 0, uploaded >= 0, downloaded >= 0, left >= 0, (0...200).contains(numWant) else { throw TorrentError.network("Invalid tracker announce parameters") }
    }
}
public struct TrackerResponse: Sendable, Equatable {
    public let peers: [PeerEndpoint]
    public let seeders: Int?
    public let leechers: Int?
    public let interval: TimeInterval
    public init(peers: [PeerEndpoint], seeders: Int? = nil, leechers: Int? = nil, interval: TimeInterval = 1800) {
        self.peers = peers; self.seeders = seeders; self.leechers = leechers; self.interval = interval
    }
}

public struct TrackerClient: Sendable {
    public init() {}
    public func announce(url: URL, request: TrackerRequest) async throws -> TrackerResponse {
        try request.validate()
        switch url.scheme?.lowercased() {
        case "http", "https": return try await httpAnnounce(url: url, request: request)
        case "udp": return try await udpAnnounce(url: url, request: request)
        default: throw TorrentError.unsupported("Unsupported tracker protocol")
        }
    }
    public static func announceURL(_ url: URL, request: TrackerRequest) throws -> URL {
        try request.validate()
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw TorrentError.network("Invalid tracker URL") }
        func binary(_ data: Data) -> String { data.map { String(format: "%%%02X", $0) }.joined() }
        var fields = ["info_hash=\(binary(request.infoHash))", "peer_id=\(binary(request.peerID))", "port=\(request.port)", "uploaded=\(request.uploaded)", "downloaded=\(request.downloaded)", "left=\(request.left)", "compact=1", "numwant=\(request.numWant)"]
        switch request.event { case .none: break; case .started: fields.append("event=started"); case .stopped: fields.append("event=stopped"); case .completed: fields.append("event=completed") }
        let query = fields.joined(separator: "&")
        components.percentEncodedQuery = (components.percentEncodedQuery.map { $0.isEmpty ? "" : $0 + "&" } ?? "") + query
        guard let result = components.url else { throw TorrentError.network("Invalid tracker announce URL") }; return result
    }
    private func httpAnnounce(url: URL, request: TrackerRequest) async throws -> TrackerResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var query = URLRequest(url: try Self.announceURL(url, request: request)); query.setValue("Torrenza/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: query)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TorrentError.network("Tracker returned an HTTP error") }
        guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw TorrentError.invalidMessage("Tracker response exceeds limit") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw TorrentError.invalidMessage("Tracker response exceeds limit") }; data.append(byte)
        }
        return try Self.decodeHTTPResponse(data)
    }
    public static func decodeHTTPResponse(_ data: Data) throws -> TrackerResponse {
        guard data.count <= 2 * 1024 * 1024 else { throw TorrentError.invalidMessage("Tracker response exceeds limit") }
        guard let dictionary = try Bencode.decode(data).dictionaryValue else { throw TorrentError.invalidMessage("Tracker response is not a dictionary") }
        if let error = dictionary["failure reason"]?.dataValue { throw TorrentError.network("Tracker: \(String(decoding: error, as: UTF8.self))") }
        var peers: [PeerEndpoint] = []
        if let compact = dictionary["peers"]?.dataValue { peers += try decodeCompactPeers(compact) }
        else if let list = dictionary["peers"]?.listValue {
            guard list.count <= 5000 else { throw TorrentError.invalidMessage("Too many tracker peers") }
            for entry in list {
                guard let peer = entry.dictionaryValue, let host = peer["ip"]?.dataValue, !host.isEmpty, host.count <= 255,
                      let port = peer["port"]?.intValue, port > 0, port <= 65535 else { continue }
                peers.append(.init(host: String(decoding: host, as: UTF8.self), port: UInt16(port)))
            }
        }
        if let compact6 = dictionary["peers6"]?.dataValue { peers += try decodeCompactPeers(compact6, ipv6: true) }
        func count(_ key: String) -> Int? { guard let value = dictionary[key]?.intValue, value >= 0, value <= Int32.max else { return nil }; return Int(value) }
        let interval = max(30, Double(dictionary["interval"]?.intValue ?? 1800), Double(dictionary["min interval"]?.intValue ?? 0))
        return .init(peers: Array(Set(peers)).sorted { ($0.host, $0.port) < ($1.host, $1.port) }, seeders: count("complete"), leechers: count("incomplete"), interval: min(interval, 86400))
    }
    public static func decodeCompactPeers(_ data: Data, ipv6: Bool = false) throws -> [PeerEndpoint] {
        let width = ipv6 ? 18 : 6
        guard data.count.isMultiple(of: width), data.count / width <= 5000 else { throw TorrentError.invalidMessage("Invalid compact peer list") }
        let b = [UInt8](data)
        var output: [PeerEndpoint] = []; output.reserveCapacity(b.count / width)
        for offset in stride(from: 0, to: b.count, by: width) {
            let port = UInt16(b[offset + width - 2]) << 8 | UInt16(b[offset + width - 1]); if port == 0 { continue }
            let host: String
            if ipv6 {
                var address = Array(b[offset..<(offset + 16)]), string = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let succeeded = address.withUnsafeMutableBytes { raw in inet_ntop(AF_INET6, raw.baseAddress, &string, socklen_t(string.count)) != nil }
                guard succeeded else { continue }; host = String(decoding: string.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } else { host = b[offset..<(offset + 4)].map(String.init).joined(separator: ".") }
            output.append(.init(host: host, port: port))
        }
        return output
    }
    private func udpAnnounce(url: URL, request: TrackerRequest) async throws -> TrackerResponse {
        guard let host = url.host, let portValue = url.port, (1...65535).contains(portValue) else { throw TorrentError.network("UDP tracker requires a host and port") }
        var lastError: any Error = TorrentError.network("UDP tracker did not respond")
        // A fresh connection avoids a timed-out receive consuming the next retry's datagram.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let transport = try NetworkTransport(endpoint: .init(host: host, port: UInt16(portValue)), udp: true)
            defer { transport.close() }
            do {
                try await transport.start(); let timeout = Double(15 * (1 << attempt))
                let connectID = UInt32.random(in: .min ... .max)
                var packet = Data(); packet.appendBE(UInt64(0x41727101980)); packet.appendBE(UInt32(0)); packet.appendBE(connectID)
                try await transport.send(packet)
                let response = try await matchingDatagram(transport, transaction: connectID, timeout: timeout)
                let b = [UInt8](response)
                try Self.validateUDPHeader(b, transaction: connectID, action: 0)
                guard b.count >= 16, let connectionID: UInt64 = b.integer(at: 8) else { throw TorrentError.invalidMessage("Truncated tracker connect response") }
                let transaction = UInt32.random(in: .min ... .max)
                packet = try Self.udpAnnouncePacket(connectionID: connectionID, transactionID: transaction, request: request)
                // BEP 41 URLData preserves tracker path and passkey for UDP trackers.
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let path = components?.percentEncodedPath ?? "/"
                let suffix = (path.isEmpty ? "/" : path) + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
                let urlData = [UInt8](suffix.utf8)
                guard urlData.count <= 2048 else { throw TorrentError.network("UDP tracker URL is too long") }
                for offset in stride(from: 0, to: urlData.count, by: 255) { let end = min(offset + 255, urlData.count); packet.append(2); packet.append(UInt8(end - offset)); packet.append(contentsOf: urlData[offset..<end]) }
                try await transport.send(packet)
                let announce = try await matchingDatagram(transport, transaction: transaction, timeout: timeout)
                var ipv6 = false
                if case .hostPort(let address, _) = transport.connection.currentPath?.remoteEndpoint, case .ipv6 = address { ipv6 = true }
                return try Self.decodeUDPResponse(announce, transactionID: transaction, ipv6: ipv6)
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }
    private func matchingDatagram(_ transport: NetworkTransport, transaction: UInt32, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            let data = try await transport.receiveDatagram(timeout: max(0.001, deadline.timeIntervalSinceNow))
            let b = [UInt8](data)
            if let received: UInt32 = b.integer(at: 4), received == transaction { return data }
        }
        throw TorrentError.network("UDP tracker response timed out")
    }
    public static func udpAnnouncePacket(connectionID: UInt64, transactionID: UInt32, request: TrackerRequest) throws -> Data {
        try request.validate()
        var packet = Data(); packet.appendBE(connectionID); packet.appendBE(UInt32(1)); packet.appendBE(transactionID)
        packet.append(request.infoHash); packet.append(request.peerID)
        packet.appendBE(UInt64(request.downloaded)); packet.appendBE(UInt64(request.left)); packet.appendBE(UInt64(request.uploaded))
        packet.appendBE(request.event.rawValue); packet.appendBE(UInt32(0)); packet.appendBE(UInt32.random(in: .min ... .max))
        packet.appendBE(UInt32(request.numWant)); packet.appendBE(request.port); return packet
    }
    public static func decodeUDPResponse(_ data: Data, transactionID: UInt32, ipv6: Bool = false) throws -> TrackerResponse {
        guard data.count <= 65_535 else { throw TorrentError.invalidMessage("Oversized tracker datagram") }
        let b = [UInt8](data); try validateUDPHeader(b, transaction: transactionID, action: 1)
        guard b.count >= 20, let interval: UInt32 = b.integer(at: 8), let leechers: UInt32 = b.integer(at: 12), let seeders: UInt32 = b.integer(at: 16) else { throw TorrentError.invalidMessage("Truncated tracker announce response") }
        return .init(peers: try decodeCompactPeers(Data(b.dropFirst(20)), ipv6: ipv6), seeders: Int(seeders), leechers: Int(leechers), interval: min(86400, max(30, Double(interval))))
    }
    private static func validateUDPHeader(_ b: [UInt8], transaction: UInt32, action: UInt32) throws {
        guard b.count >= 8, let received: UInt32 = b.integer(at: 4), received == transaction, let receivedAction: UInt32 = b.integer(at: 0) else { throw TorrentError.invalidMessage("Invalid tracker transaction") }
        if receivedAction == 3 { throw TorrentError.network("Tracker: \(String(decoding: b.dropFirst(8), as: UTF8.self))") }
        guard receivedAction == action else { throw TorrentError.invalidMessage("Unexpected tracker action") }
    }
}
