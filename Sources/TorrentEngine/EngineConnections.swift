import Foundation
import Network
import TorrentCore
import TorrentWire

/// A slot is held from before a handshake starts until registration atomically
/// replaces it with an established peer. Actor suspension never frees capacity.
struct ConnectionAdmission {
    var sessionID: String?
    var generation: Int?
    var task: Task<Void, Never>?
}

extension TorrentEngine {
    var totalPeers: Int { connectionAdmissions.count + sessions.values.reduce(0) { $0 + $1.peers.count } }
    var pendingIncoming: Int { connectionAdmissions.values.filter { $0.sessionID == nil }.count }

    func handshakes(for id: String) -> Int {
        connectionAdmissions.values.filter { $0.sessionID == id }.count
    }

    func reserveConnection(for id: String?) -> UUID? {
        guard !shuttingDown, totalPeers < effectivePeerLimit, connectionAdmissions.count < 64 else { return nil }
        if let id {
            guard let session = sessions[id], [.downloading, .seeding].contains(session.snapshot.state), handshakes(for: id) < 16 else { return nil }
            let token = UUID()
            connectionAdmissions[token] = ConnectionAdmission(sessionID: id, generation: session.generation)
            return token
        }
        let token = UUID()
        connectionAdmissions[token] = ConnectionAdmission()
        return token
    }

    func readyCandidate(_ session: EngineSession) -> PeerEndpoint? {
        let now = Date()
        var remaining = session.candidates.count
        while remaining > 0, !session.candidates.isEmpty {
            remaining -= 1
            let endpoint = session.candidates.removeFirst()
            if session.connecting.contains(endpoint) || session.peers.values.contains(where: { $0.endpoint == endpoint }) { continue }
            if let last = session.lastAttempt[endpoint], now.timeIntervalSince(last) < 30 {
                session.candidates.append(endpoint)
                continue
            }
            return endpoint
        }
        return nil
    }

    func waitingCandidateCount(_ session: EngineSession, limit: Int = 16) -> Int {
        let connected = Set(session.peers.values.map(\.endpoint))
        let now = Date()
        var count = 0
        for endpoint in session.candidates where !session.connecting.contains(endpoint) && !connected.contains(endpoint) {
            if now.timeIntervalSince(session.lastAttempt[endpoint] ?? .distantPast) >= 30 {
                count += 1
                if count == limit { break }
            }
        }
        return count
    }

    func hasWaitingCandidates(_ session: EngineSession) -> Bool {
        waitingCandidateCount(session, limit: 1) > 0
    }

    /// One attempt per torrent per round. Torrents without usable candidates do
    /// not strand their share; a single populated swarm can borrow the full cap.
    func connectCandidates(_ id: String) {
        guard !shuttingDown else { return }
        let ids = sessions.keys.sorted().filter { sessions[$0].map { [.downloading, .seeding].contains($0.snapshot.state) } ?? false }
        guard !ids.isEmpty else { return }
        let start = connectionCursor % ids.count
        let order = Array(ids[start...] + ids[..<start])
        connectionCursor = (start + 1) % ids.count
        var advanced = true
        while advanced && totalPeers < effectivePeerLimit && connectionAdmissions.count < 64 {
            advanced = false
            for current in order {
                guard totalPeers < effectivePeerLimit, connectionAdmissions.count < 64 else { break }
                guard let session = sessions[current], handshakes(for: current) < 16 else { continue }
                let share = max(1, effectivePeerLimit / ids.count)
                if session.peers.count + handshakes(for: current) >= share,
                   ids.contains(where: { other in
                       guard other != current, let waiting = sessions[other], handshakes(for: other) < 16 else { return false }
                       return waiting.peers.count + handshakes(for: other) < share && hasWaitingCandidates(waiting)
                   }) { continue }
                guard let endpoint = readyCandidate(session), let admission = reserveConnection(for: current) else { continue }
                advanced = true
                session.lastAttempt[endpoint] = Date()
                session.connecting.insert(endpoint)
                let taskID = UUID()
                let task = startBackgroundTask { engine in
                    await engine.connect(current, endpoint: endpoint, admission: admission)
                    engine.sessions[current]?.connectionTasks.removeValue(forKey: taskID)
                }
                session.connectionTasks[taskID] = task
                connectionAdmissions[admission]?.task = task
            }
        }
    }

    func idlePeer(in session: EngineSession) -> UUID? {
        session.peers.min { lhs, rhs in
            let leftIdle = lhs.value.pending.isEmpty && !lhs.value.interested
            let rightIdle = rhs.value.pending.isEmpty && !rhs.value.interested
            if leftIdle != rightIdle { return leftIdle }
            return lhs.value.lastMessage < rhs.value.lastMessage
        }?.key
    }

    /// Reclaim borrowed established slots only for real waiting demand. Settings
    /// reductions also retire excess slots, including cancellable handshakes.
    func rebalanceConnections() async {
        // Connection scratch reservations are long lived. A live budget decrease
        // must retire idle connections too, otherwise they alone could prevent
        // any payload request from ever freeing memory below the new ceiling.
        let payloadCeiling = max(0, await budget.limit - budget.verificationHeadroom)
        while sessions.values.reduce(0, { $0 + $1.peers.values.reduce(0) { $0 + $1.receiveReservation } }) > max(0, payloadCeiling - 16_384) {
            guard let donor = sessions.values.filter({ !$0.peers.isEmpty }).max(by: { $0.peers.count < $1.peers.count }),
                  let key = idlePeer(in: donor) else { break }
            await disconnect(donor.record.metainfo.id, key: key)
        }
        if totalPeers > effectivePeerLimit {
            var excess = totalPeers - effectivePeerLimit
            for admission in connectionAdmissions.values where excess > 0 {
                admission.task?.cancel()
                excess -= 1
            }
            while excess > 0 {
                guard let donor = sessions.values.filter({ !$0.peers.isEmpty }).max(by: { $0.peers.count < $1.peers.count }),
                      let key = idlePeer(in: donor) else { break }
                await disconnect(donor.record.metainfo.id, key: key)
                excess -= 1
            }
        }
        let active = sessions.values.filter { [.downloading, .seeding].contains($0.snapshot.state) }
        guard !active.isEmpty else { return }
        let share = max(1, effectivePeerLimit / active.count)
        for receiver in active where hasWaitingCandidates(receiver) && handshakes(for: receiver.record.metainfo.id) < 16 {
            let demand = min(share - receiver.peers.count - handshakes(for: receiver.record.metainfo.id),
                             16 - handshakes(for: receiver.record.metainfo.id), waitingCandidateCount(receiver))
            guard demand > 0 else { continue }
            let reclaim = max(0, demand - max(0, effectivePeerLimit - totalPeers))
            for _ in 0..<reclaim {
                guard let donor = active.filter({ $0 !== receiver && $0.peers.count > (effectivePeerLimit < active.count ? 0 : share) }).max(by: { $0.peers.count < $1.peers.count }),
                      let key = idlePeer(in: donor) else { break }
                await disconnect(donor.record.metainfo.id, key: key)
            }
        }
        connectCandidates("")
    }

    func connect(_ id: String, endpoint: PeerEndpoint, admission: UUID) async {
        guard let session = sessions[id], let generation = connectionAdmissions[admission]?.generation else {
            connectionAdmissions.removeValue(forKey: admission)
            return
        }
        defer {
            connectionAdmissions.removeValue(forKey: admission)
            session.connecting.remove(endpoint)
            if sessions[id] === session, session.generation == generation, !session.peers.values.contains(where: { $0.endpoint == endpoint }), !session.candidates.contains(endpoint) {
                session.candidates.append(endpoint)
            }
        }
        do {
            try Task.checkCancellation()
            let cap = max(32_768, session.record.verified.bytes.count + 1)
            let connection = try PeerConnection(endpoint: endpoint, maximumFrameLength: cap)
            do {
                let handshake = try await connection.connect(infoHash: session.record.metainfo.infoHash, peerID: peerID, supportsDHT: !session.record.metainfo.isPrivate)
                guard sessions[id] === session, session.generation == generation, !Task.isCancelled, handshake.peerID != peerID else { await connection.close(); return }
                try await register(id, connection: connection, endpoint: endpoint, handshake: handshake, admission: admission)
            } catch { await connection.close() }
        } catch { /* A failed candidate is isolated from the transfer. */ }
    }

    func accept(_ raw: NWConnection, admission: UUID) async {
        defer { connectionAdmissions.removeValue(forKey: admission) }
        guard !shuttingDown, connectionAdmissions[admission] != nil, !Task.isCancelled else { raw.cancel(); return }
        let connection = PeerConnection(connection: raw)
        do {
            let handshake = try await connection.receiveHandshake()
            let id = handshake.infoHash.hexString
            guard !shuttingDown, !Task.isCancelled, let session = sessions[id], [.downloading, .seeding].contains(session.snapshot.state), handshake.peerID != peerID,
                  handshakes(for: id) < 16 else { await connection.close(); return }
            connectionAdmissions[admission]?.sessionID = id
            connectionAdmissions[admission]?.generation = session.generation
            try await connection.sendHandshake(infoHash: handshake.infoHash, peerID: peerID, supportsDHT: !session.record.metainfo.isPrivate)
            let endpoint: PeerEndpoint
            if case .hostPort(let host, let port) = raw.endpoint { endpoint = PeerEndpoint(host: "\(host)", port: port.rawValue) }
            else { endpoint = PeerEndpoint(host: "incoming", port: 0) }
            try await register(id, connection: connection, endpoint: endpoint, handshake: handshake, admission: admission, isOutbound: false)
        } catch { await connection.close() }
    }

    func register(_ id: String, connection: PeerConnection, endpoint: PeerEndpoint, handshake: PeerHandshake, admission: UUID, isOutbound: Bool = true) async throws {
        guard let session = sessions[id], let token = connectionAdmissions[admission], token.sessionID == id, let generation = token.generation else { await connection.close(); return }
        func valid() -> Bool {
            !shuttingDown && !Task.isCancelled && sessions[id] === session && session.generation == generation &&
            session.record.quarantineError == nil && [.downloading, .seeding].contains(session.snapshot.state) &&
            connectionAdmissions[admission] != nil && totalPeers <= effectivePeerLimit
        }
        guard valid() else { await connection.close(); return }
        let cap = max(32_768, session.record.verified.bytes.count + 1)
        // Leave at least one block of payload capacity beyond long-lived
        // connection scratch, including after reducing the live budget.
        guard await budget.tryAcquire(cap * 4 + 16_384) else { await connection.close(); return }
        await budget.release(16_384)
        guard valid() else { await budget.release(cap * 4); await connection.close(); return }
        await connection.setMaximumFrameLength(cap)
        guard valid() else { await budget.release(cap * 4); await connection.close(); return }
        let key = UUID()
        // No await between consuming the token and inserting its established peer.
        connectionAdmissions.removeValue(forKey: admission)
        session.peers[key] = ActivePeer(connection: connection, endpoint: endpoint, availability: PieceBitset(count: session.wanted.count))
        session.peers[key]?.receiveReservation = cap * 4
        session.peers[key]?.isOutbound = isOutbound
        do {
            try await connection.send(.bitfield(session.record.verified.bytes))
            if handshake.supportsExtensions {
                try await connection.send(.extended(id: 0, payload: PeerExtensions.extendedHandshake(metadataSize: session.record.metainfo.rawInfo.count, allowPEX: !session.record.metainfo.isPrivate)))
            }
            if !session.selectedComplete { try await connection.send(.interested) }
            guard sessions[id] === session, session.generation == generation, session.peers[key] != nil, !Task.isCancelled else { await disconnect(id, key: key); return }
            session.peers[key]?.task = startBackgroundTask { engine in
                do {
                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        guard let current = engine.sessions[id], current.generation == generation, current.peers[key] != nil else { break }
                        try await engine.handle(id, key: key, message: message)
                    }
                } catch { /* Disconnect releases all outstanding reservations. */ }
                await engine.disconnect(id, key: key)
            }
        } catch { await disconnect(id, key: key); throw error }
    }
}
