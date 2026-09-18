import Foundation
import Network
import CryptoKit
import TorrentCore

/// Bounded BEP 5/32 discovery node. Only validated responses enter the routing table.
public actor DHTClient {
    private struct Contact: Codable, Sendable { let id: Data; let endpoint: PeerEndpoint; var seen: Date }
    private struct Token: Sendable { let endpoint: PeerEndpoint; let value: Data; let received: Date }
    private struct StoredPeer: Sendable { let endpoint: PeerEndpoint; let expires: Date }
    private var nodeID: Data
    private let explicitNodeID: Bool
    private var addressVotes: [String: Set<String>] = [:]
    private let bootstrapNodes: [PeerEndpoint]
    private let persistenceURL: URL?
    private let secret = SymmetricKey(size: .bits256)
    private var contacts: [PeerEndpoint: Contact] = [:]
    private var tokens: [Data: [Token]] = [:]
    private var storedPeers: [Data: [StoredPeer]] = [:]
    private var generation = UUID()
    private var listener: NWListener?
    private var listenerReady: [CheckedContinuation<Void, any Error>] = []
    private var incoming: [UUID: NWConnection] = [:]
    private var exchanges: [UUID: DHTExchange] = [:]
    private var queryingEndpoints = Set<PeerEndpoint>()
    private var stopped = false
    private var queriesThisSecond = 0
    private var querySecond: Int64 = 0
    public private(set) var boundPort: UInt16 = 0
    public init(nodeID: Data? = nil, bootstrapNodes: [PeerEndpoint] = EngineSettings().bootstrapNodes, persistenceURL: URL? = nil, persistedContacts: Data? = nil) {
        self.nodeID = nodeID?.count == 20 ? nodeID! : Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        self.explicitNodeID = nodeID?.count == 20
        self.bootstrapNodes = Array(bootstrapNodes.prefix(16)); self.persistenceURL = persistenceURL
        var stored = persistedContacts
        if stored == nil, let url = persistenceURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024 {
            stored = try? Data(contentsOf: url)
        }
        if let stored, stored.count <= 256 * 1024, let saved = try? JSONDecoder().decode([Contact].self, from: stored) {
            for contact in saved.prefix(512) where contact.id.count == 20 && contact.endpoint.port != 0 && contact.endpoint.host.utf8.count <= 255 { contacts[contact.endpoint] = contact }
        }
    }
    /// Opaque bounded contact data for storage in the application's shared SQLite transaction.
    public func contactsSnapshot() -> Data {
        (try? JSONEncoder().encode(Array(contacts.values.prefix(512)))) ?? Data("[]".utf8)
    }
    public func importContacts(_ data: Data) throws {
        guard data.count <= 256 * 1024 else { throw TorrentError.invalidMessage("DHT contact snapshot exceeds its size limit") }
        let saved = try JSONDecoder().decode([Contact].self, from: data)
        guard saved.count <= 512, saved.allSatisfy({ $0.id.count == 20 && $0.endpoint.port != 0 && $0.endpoint.host.utf8.count <= 255 }) else { throw TorrentError.invalidMessage("Invalid persisted DHT contacts") }
        for contact in saved { remember(contact) }
    }
    public func start(port: UInt16 = 0) async throws {
        if listener != nil {
            if boundPort == 0 {
                try await withCheckedThrowingContinuation { listenerReady.append($0) }
            }
            try Task.checkCancellation()
            return
        }
        stopped = false
        generation = UUID(); let currentGeneration = generation
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = server
        server.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listenerReady.append(continuation)
            server.stateUpdateHandler = { [weak self, weak server] state in
                switch state {
                case .ready: Task { await self?.ready(port: server?.port?.rawValue ?? 0, generation: currentGeneration) }
                case .failed(let error): Task { await self?.listenerFailed(error, generation: currentGeneration) }
                case .cancelled: Task { await self?.listenerFailed(TorrentError.cancelled, generation: currentGeneration) }
                default: break
                }
            }
            server.start(queue: .global(qos: .utility))
        }
    }
    private func ready(port: UInt16, generation: UUID) {
        guard self.generation == generation, !stopped, listener != nil else { return }
        boundPort = port
        let waiting = listenerReady; listenerReady.removeAll()
        for continuation in waiting { continuation.resume() }
    }
    private func listenerFailed(_ error: any Error, generation: UUID) {
        guard self.generation == generation else { return }
        let waiting = listenerReady; listenerReady.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil; boundPort = 0
    }
    public func stop() async {
        stopped = true; generation = UUID()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil; boundPort = 0
        let waiting = listenerReady; listenerReady.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        for connection in incoming.values { connection.cancel() }; incoming.removeAll()
        for exchange in exchanges.values { exchange.cancel() }; exchanges.removeAll()
        tokens.removeAll(); storedPeers.removeAll()
        await persist()
    }
    public func peers(infoHash: Data) async throws -> [PeerEndpoint] {
        guard infoHash.count == 20 else { throw TorrentError.invalidMessage("DHT info hash must be 20 bytes") }
        if listener == nil || boundPort == 0 { try await start() }
        try Task.checkCancellation()
        let initialContacts = closest(to: infoHash)
        var knownIDs = Dictionary(uniqueKeysWithValues: initialContacts.map { ($0.endpoint, $0.id) })
        var candidates = initialContacts.map(\.endpoint)
        candidates += bootstrapNodes.filter { !candidates.contains($0) }
        var visited = Set<PeerEndpoint>(), peers = Set<PeerEndpoint>(), receivedTokens: [Token] = []
        var successfulResponses = 0
        // Alpha=3 parallel requests. Hard caps prevent malicious referral chains and unbounded work.
        for _ in 0..<16 {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            let batch = Array(candidates.filter { !visited.contains($0) }.sorted { left, right in
                guard let a = knownIDs[left] else { return false }
                guard let b = knownIDs[right] else { return true }
                for i in 0..<20 { let x = a[i] ^ infoHash[i], y = b[i] ^ infoHash[i]; if x != y { return x < y } }
                return false
            }.prefix(3))
            if batch.isEmpty { break }
            visited.formUnion(batch)
            let replies = await withTaskGroup(of: (PeerEndpoint, [String: BencodeValue]?).self) { group in
                for endpoint in batch {
                    group.addTask {
                    do { return (endpoint, try await self.query("get_peers", arguments: ["info_hash": .bytes(infoHash), "want": .list([.bytes(Data("n4".utf8)), .bytes(Data("n6".utf8))])], to: endpoint)) }
                    catch { return (endpoint, nil) }
                }
                }
                var replies: [(PeerEndpoint, [String: BencodeValue]?)] = []
                for await reply in group { replies.append(reply) }
                return replies
            }
            for (endpoint, reply) in replies {
                guard let reply else { continue }
                successfulResponses += 1
                if let token = reply["token"]?.dataValue, !token.isEmpty, token.count <= 256 {
                    receivedTokens.append(Token(endpoint: endpoint, value: token, received: Date()))
                }
                if let values = reply["values"]?.listValue {
                    for value in values.prefix(128) {
                        guard let bytes = value.dataValue, bytes.count == 6 || bytes.count == 18,
                              let found = try? CompactAddress.decode(bytes, ipv6: bytes.count == 18) else { continue }
                        peers.formUnion(found)
                    }
                }
                for (field, ipv6) in [("nodes", false), ("nodes6", true)] {
                    guard let data = reply[field]?.dataValue else { continue }
                    for contact in Self.decodeNodes(data, ipv6: ipv6) where !visited.contains(contact.endpoint) && !candidates.contains(contact.endpoint) {
                        if candidates.count < 256 { candidates.append(contact.endpoint); knownIDs[contact.endpoint] = contact.id }
                    }
                }
            }
            if peers.count >= 128 { break }
        }
        try Task.checkCancellation()
        if successfulResponses == 0 && !visited.isEmpty { throw TorrentError.network("No DHT nodes responded; check the connection or bootstrap endpoints") }
        if tokens.count >= 64 && tokens[infoHash] == nil { tokens.removeValue(forKey: tokens.keys.first!) }
        tokens[infoHash] = Array(receivedTokens.prefix(16))
        await persist()
        return Array(peers.prefix(128))
    }
    public func announce(infoHash: Data, port: UInt16) async {
        guard infoHash.count == 20, port != 0, !stopped else { return }
        if tokens[infoHash]?.contains(where: { Date().timeIntervalSince($0.received) < 300 }) != true { _ = try? await peers(infoHash: infoHash) }
        for token in (tokens[infoHash] ?? []).prefix(8) where Date().timeIntervalSince(token.received) < 300 {
            if Task.isCancelled || stopped { return }
            _ = try? await query("announce_peer", arguments: ["info_hash": .bytes(infoHash), "port": .integer(Int64(port)), "implied_port": .integer(0), "token": .bytes(token.value)], to: token.endpoint)
        }
    }
    private func query(_ method: String, arguments: [String: BencodeValue], to endpoint: PeerEndpoint) async throws -> [String: BencodeValue] {
        try Task.checkCancellation()
        guard !stopped, exchanges.count < 48, endpoint.port > 0 else { throw TorrentError.network("DHT unavailable or busy") }
        // A connected UDP socket shares the listening port. Serialize identical destinations
        // so two simultaneous sockets cannot consume each other's replies on the same 5-tuple.
        let waitDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while queryingEndpoints.contains(endpoint) {
            try await Task.sleep(for: .milliseconds(20))
            guard !stopped, ContinuousClock.now < waitDeadline else { throw TorrentError.network("DHT endpoint busy") }
        }
        try Task.checkCancellation()
        queryingEndpoints.insert(endpoint)
        defer { queryingEndpoints.remove(endpoint) }
        var arguments = arguments; arguments["id"] = .bytes(nodeID)
        let transaction = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        var envelope: [String: BencodeValue] = ["t": .bytes(transaction), "y": .bytes(Data("q".utf8)), "q": .bytes(Data(method.utf8)), "a": .dictionary(arguments)]
        // Network.framework cannot share a listener's IPv6 port with a separate outbound flow.
        // BEP 43 prevents these ephemeral IPv6 endpoints entering another node's routing table.
        if IPv6Address(endpoint.host) != nil { envelope["ro"] = .integer(1) }
        let packet = Bencode.encode(.dictionary(envelope))
        let exchange = DHTExchange(endpoint: endpoint, packet: packet, localPort: boundPort)
        let key = UUID(); exchanges[key] = exchange
        defer { exchanges.removeValue(forKey: key) }
        let data = try await withTaskCancellationHandler { try await exchange.run() } onCancel: { exchange.cancel() }
        guard data.count <= 8192, let message = try Bencode.decode(data).dictionaryValue,
              message["t"]?.dataValue == transaction else { throw TorrentError.invalidMessage("Invalid DHT transaction") }
        let remote = exchange.remoteEndpoint ?? endpoint
        if let external = message["ip"]?.dataValue { observeExternalAddress(external, source: remote) }
        guard message["y"]?.dataValue == Data("r".utf8),
              let response = message["r"]?.dictionaryValue, let id = response["id"]?.dataValue, id.count == 20 else { throw TorrentError.invalidMessage("Invalid DHT response") }
        if id != nodeID { remember(Contact(id: id, endpoint: remote, seen: Date())) }
        var validated = response
        if !Self.validNodeID(id, host: remote.host) { validated.removeValue(forKey: "token") }
        return validated
    }
    private func observeExternalAddress(_ compact: Data, source: PeerEndpoint) {
        guard !explicitNodeID, compact.count == 6 || compact.count == 18,
              let observed = try? CompactAddress.decode(compact, ipv6: compact.count == 18).first,
              !Self.isLocalAddress(observed.host), !Self.isLocalAddress(source.host) else { return }
        if addressVotes.count >= 8, addressVotes[observed.host] == nil { return }
        // Two distinct source IPs must agree before accepting an unsolicited external-address report.
        if addressVotes[observed.host, default: []].count < 8 { addressVotes[observed.host, default: []].insert(source.host) }
        guard addressVotes[observed.host]!.count >= 2,
              !Self.validNodeID(nodeID, host: observed.host),
              let generated = Self.makeNodeID(host: observed.host, random: nodeID) else { return }
        nodeID = generated; addressVotes.removeAll(); tokens.removeAll()
    }
    static func makeNodeID(host: String, random: Data) -> Data? {
        guard random.count == 20, let compact = CompactAddress.encode(PeerEndpoint(host: host, port: 1)) else { return nil }
        let masks: [UInt8] = compact.count == 6 ? [3, 15, 63, 255] : [1, 3, 7, 15, 31, 63, 127, 255]
        var bytes = Array(compact.prefix(masks.count))
        for i in bytes.indices { bytes[i] &= masks[i] }
        bytes[0] |= (random[19] & 7) << 5
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0x82f6_3b78 : 0) }
        }
        crc = ~crc
        var output = random
        output[0] = UInt8(truncatingIfNeeded: crc >> 24); output[1] = UInt8(truncatingIfNeeded: crc >> 16)
        output[2] = (UInt8(truncatingIfNeeded: crc >> 8) & 0xf8) | (random[2] & 7)
        return output
    }
    static func validNodeID(_ id: Data, host: String) -> Bool {
        guard id.count == 20 else { return false }
        if isLocalAddress(host) { return true }
        guard let expected = makeNodeID(host: host, random: id) else { return false }
        return id[0] == expected[0] && id[1] == expected[1] && id[2] & 0xf8 == expected[2] & 0xf8
    }
    private static func isLocalAddress(_ host: String) -> Bool {
        if let v4 = IPv4Address(host) {
            let b = Array(v4.rawValue)
            return b[0] == 10 || b[0] == 127 || b[0] == 0 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        if let v6 = IPv6Address(host) {
            let b = Array(v6.rawValue)
            return v6 == .loopback || v6 == .any || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        }
        return false
    }
    private func remember(_ contact: Contact) {
        // Eight contacts per XOR prefix bucket and 512 globally; retain recently responsive nodes.
        let bucket = prefixBucket(contact.id)
        let family = CompactAddress.encode(contact.endpoint)?.count
        let existing = contacts.values.filter { prefixBucket($0.id) == bucket && CompactAddress.encode($0.endpoint)?.count == family }
        if contacts[contact.endpoint] == nil, existing.count >= 8 {
            if let oldest = existing.min(by: { $0.seen < $1.seen }), Date().timeIntervalSince(oldest.seen) > 900 { contacts.removeValue(forKey: oldest.endpoint) } else { return }
        }
        if contacts.count >= 512, contacts[contact.endpoint] == nil, let oldest = contacts.values.min(by: { $0.seen < $1.seen }) { contacts.removeValue(forKey: oldest.endpoint) }
        contacts[contact.endpoint] = contact
    }
    private func prefixBucket(_ id: Data) -> Int {
        for i in 0..<20 { let byte = id[i] ^ nodeID[i]; if byte != 0 { return i * 8 + byte.leadingZeroBitCount } }
        return 160
    }
    private func closest(to target: Data) -> [Contact] {
        contacts.values.sorted { left, right in
            for i in 0..<20 { let a = left.id[i] ^ target[i], b = right.id[i] ^ target[i]; if a != b { return a < b } }
            return false
        }.prefix(32).map { $0 }
    }
    private static func decodeNodes(_ data: Data, ipv6: Bool) -> [Contact] {
        let stride = ipv6 ? 38 : 26
        guard data.count.isMultiple(of: stride), data.count / stride <= 128 else { return [] }
        return Swift.stride(from: 0, to: data.count, by: stride).compactMap { offset in
            let entry = Data(data.dropFirst(offset).prefix(stride))
            guard let endpoint = try? CompactAddress.decode(Data(entry.dropFirst(20)), ipv6: ipv6).first else { return nil }
            return Contact(id: Data(entry.prefix(20)), endpoint: endpoint, seen: .distantPast)
        }
    }
    private func persist() async {
        guard let url = persistenceURL else { return }
        let data = contactsSnapshot()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch { /* Persistence is advisory; network discovery remains available. */ }
                continuation.resume()
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, incoming.count < 64 else { connection.cancel(); return }
        let key = UUID(); incoming[key] = connection
        connection.start(queue: .global(qos: .utility))
        receiveIncoming(connection, key: key)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { await self?.closeIncoming(key) }
        }
    }
    private func receiveIncoming(_ connection: NWConnection, key: UUID) {
        guard !stopped, incoming[key] != nil else { return }
        connection.receiveMessage { [weak self] data, _, _, _ in
            Task { await self?.respond(data, connection: connection, key: key) }
        }
    }
    private func sentIncoming(_ connection: NWConnection, key: UUID, failed: Bool) {
        if failed { closeIncoming(key) } else { receiveIncoming(connection, key: key) }
    }
    private func closeIncoming(_ key: UUID) { incoming.removeValue(forKey: key)?.cancel() }
    private func respond(_ data: Data?, connection: NWConnection, key: UUID) {
        guard !stopped, incoming[key] != nil else { closeIncoming(key); return }
        let second = Int64(Date().timeIntervalSince1970)
        if second != querySecond { querySecond = second; queriesThisSecond = 0 }
        queriesThisSecond += 1
        guard queriesThisSecond <= 100, let data, data.count <= 4096,
              let message = try? Bencode.decode(data).dictionaryValue,
              message["y"]?.dataValue == Data("q".utf8), let transaction = message["t"]?.dataValue, transaction.count <= 8,
              let methodData = message["q"]?.dataValue, let method = String(data: methodData, encoding: .utf8),
              let arguments = message["a"]?.dictionaryValue, arguments["id"]?.dataValue?.count == 20,
              let endpoint = Self.endpoint(connection.endpoint) else { closeIncoming(key); return }
        var response: [String: BencodeValue] = ["id": .bytes(nodeID)]
        var error: String?
        switch method {
        case "ping": break
        case "find_node", "get_peers":
            let target = arguments[method == "find_node" ? "target" : "info_hash"]?.dataValue
            guard let target, target.count == 20 else { closeIncoming(key); return }
            var v4 = Data(), v6 = Data()
            for contact in closest(to: target).filter({ Date().timeIntervalSince($0.seen) < 900 }).prefix(8) {
                guard let compact = CompactAddress.encode(contact.endpoint) else { continue }
                if compact.count == 6 { v4 += contact.id + compact } else { v6 += contact.id + compact }
            }
            let requested = arguments["want"]?.listValue?.compactMap(\.stringValue)
            let isV6 = CompactAddress.encode(endpoint)?.count == 18
            if requested?.contains("n4") ?? !isV6 { response["nodes"] = .bytes(v4) }
            if requested?.contains("n6") ?? isV6 { response["nodes6"] = .bytes(v6) }
            if method == "get_peers" {
                response["token"] = .bytes(makeToken(host: endpoint.host, bucket: second / 300))
                let live = (storedPeers[target] ?? []).filter { $0.expires > Date() }
                if !live.isEmpty { response["values"] = .list(live.prefix(16).compactMap { CompactAddress.encode($0.endpoint).map(BencodeValue.bytes) }) }
            }
        case "announce_peer":
            guard let hash = arguments["info_hash"]?.dataValue, hash.count == 20,
                  let suppliedToken = arguments["token"]?.dataValue else { closeIncoming(key); return }
            let valid = (0...1).contains { suppliedToken == makeToken(host: endpoint.host, bucket: second / 300 - Int64($0)) }
            let port = arguments["implied_port"]?.intValue == 1 ? Int64(endpoint.port) : arguments["port"]?.intValue ?? 0
            if !valid || !(1...65535).contains(port) { error = "Invalid token or port" }
            else {
                if storedPeers.count >= 64 && storedPeers[hash] == nil { storedPeers.removeValue(forKey: storedPeers.keys.first!) }
                let peer = PeerEndpoint(host: endpoint.host, port: UInt16(port))
                var list = (storedPeers[hash] ?? []).filter { $0.expires > Date() && $0.endpoint != peer }
                list.append(StoredPeer(endpoint: peer, expires: Date().addingTimeInterval(1800)))
                storedPeers[hash] = Array(list.suffix(128))
            }
        default: error = "Unknown method"
        }
        var reply: [String: BencodeValue] = ["t": .bytes(transaction)]
        if let compact = CompactAddress.encode(endpoint) { reply["ip"] = .bytes(compact) }
        if let error { reply["y"] = .bytes(Data("e".utf8)); reply["e"] = .list([.integer(method == "announce_peer" ? 203 : 204), .bytes(Data(error.utf8))]) }
        else { reply["y"] = .bytes(Data("r".utf8)); reply["r"] = .dictionary(response) }
        connection.send(content: Bencode.encode(.dictionary(reply)), completion: .contentProcessed { [weak self] error in Task { await self?.sentIncoming(connection, key: key, failed: error != nil) } })
    }
    private func makeToken(host: String, bucket: Int64) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("\(host)|\(bucket)".utf8), using: secret).prefix(16))
    }
    fileprivate static func endpoint(_ endpoint: NWEndpoint) -> PeerEndpoint? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return PeerEndpoint(host: address.debugDescription, port: port.rawValue)
        case .ipv6(let address): return PeerEndpoint(host: address.debugDescription, port: port.rawValue)
        case .name(let name, _): return PeerEndpoint(host: name, port: port.rawValue)
        @unknown default: return nil
        }
    }
}

/// A single UDP request has a bounded lifetime and exactly one continuation completion.
private final class DHTExchange: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let packet: Data
    private var continuation: CheckedContinuation<Data, any Error>?
    private var finished = false
    init(endpoint: PeerEndpoint, packet: Data, localPort: UInt16) {
        self.packet = packet
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if localPort != 0 && IPv6Address(endpoint.host) == nil {
            let host: NWEndpoint.Host = .ipv4(.any)
            parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: localPort)!)
        }
        self.connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
    }
    private var resolvedEndpoint: PeerEndpoint?
    var remoteEndpoint: PeerEndpoint? { lock.lock(); defer { lock.unlock() }; return resolvedEndpoint }
    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation; lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connection.send(content: self.packet, completion: .contentProcessed { [weak self] error in
                        if let error { self?.finish(.failure(error)) }
                    })
                    self.connection.receiveMessage { [weak self] data, _, _, error in
                        if let error { self?.finish(.failure(error)) }
                        else if let data { self?.finish(.success(data)) }
                        else { self?.finish(.failure(TorrentError.network("Empty DHT response"))) }
                    }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(.failure(TorrentError.network("DHT request timed out"))) }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; resolvedEndpoint = connection.currentPath?.remoteEndpoint.flatMap { DHTClient.endpoint($0) }
        let completion = continuation; continuation = nil; lock.unlock()
        connection.cancel(); completion?.resume(with: result)
    }
}
