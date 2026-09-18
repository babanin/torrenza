import Foundation
import Network
import TorrentCore
import TorrentWire

extension TorrentEngine {
    var totalPeers: Int { pendingIncoming + sessions.values.reduce(0) { $0 + $1.peers.count + $1.connecting.count } }

    func connectCandidates(_ id: String) {
        guard !shuttingDown, let session = sessions[id], [.downloading, .seeding].contains(session.snapshot.state) else { return }
        let active = max(1, sessions.values.filter { [.downloading, .seeding].contains($0.snapshot.state) }.count)
        let perTransfer = max(1, effectivePeerLimit / active)
        var attempts = session.candidates.count
        while attempts > 0, totalPeers < effectivePeerLimit, session.peers.count + session.connecting.count < perTransfer, !session.candidates.isEmpty {
            attempts -= 1
            let endpoint = session.candidates.removeFirst()
            if let last = session.lastAttempt[endpoint], Date().timeIntervalSince(last) < 30 { session.candidates.append(endpoint); continue }
            session.lastAttempt[endpoint] = Date()
            guard !session.connecting.contains(endpoint), !session.peers.values.contains(where: { $0.endpoint == endpoint }) else { continue }
            session.connecting.insert(endpoint)
            let taskID = UUID()
            session.connectionTasks[taskID] = startBackgroundTask { engine in await engine.connect(id, endpoint: endpoint); engine.sessions[id]?.connectionTasks.removeValue(forKey: taskID) }
        }
    }

    func connect(_ id: String, endpoint: PeerEndpoint) async {
        guard let session = sessions[id] else { return }
        let generation = session.generation
        defer {
            session.connecting.remove(endpoint)
            if session.generation == generation && !session.peers.values.contains(where: { $0.endpoint == endpoint }) { session.candidates.append(endpoint) }
        }
        do {
            let cap = max(32_768, session.record.verified.bytes.count + 1)
            let connection = try PeerConnection(endpoint: endpoint, maximumFrameLength: cap)
            do {
                let handshake = try await connection.connect(infoHash: session.record.metainfo.infoHash, peerID: peerID, supportsDHT: !session.record.metainfo.isPrivate)
                guard session.generation == generation, !Task.isCancelled, handshake.peerID != peerID, [.downloading, .seeding].contains(session.snapshot.state) else { await connection.close(); return }
                try await register(id, connection: connection, endpoint: endpoint, handshake: handshake)
            } catch { await connection.close() }
        } catch { /* A failed candidate is isolated from the transfer. */ }
    }

    func accept(_ raw: NWConnection) async {
        guard !shuttingDown, totalPeers < effectivePeerLimit else { raw.cancel(); return }
        pendingIncoming += 1
        defer { pendingIncoming -= 1 }
        let connection = PeerConnection(connection: raw)
        do {
            let handshake = try await connection.receiveHandshake()
            let id = handshake.infoHash.hexString
            guard !shuttingDown, let session = sessions[id], [.downloading, .seeding].contains(session.snapshot.state), handshake.peerID != peerID,
                  totalPeers < effectivePeerLimit else { await connection.close(); return }
            try await connection.sendHandshake(infoHash: handshake.infoHash, peerID: peerID, supportsDHT: !session.record.metainfo.isPrivate)
            let endpoint: PeerEndpoint
            if case .hostPort(let host, let port) = raw.endpoint { endpoint = PeerEndpoint(host: "\(host)", port: port.rawValue) }
            else { endpoint = PeerEndpoint(host: "incoming", port: 0) }
            try await register(id, connection: connection, endpoint: endpoint, handshake: handshake, isOutbound: false)
        } catch { await connection.close() }
    }

    func register(_ id: String, connection: PeerConnection, endpoint: PeerEndpoint, handshake: PeerHandshake, isOutbound: Bool = true) async throws {
        guard !shuttingDown, let session = sessions[id] else { await connection.close(); return }
        let cap = max(32_768, session.record.verified.bytes.count + 1)
        guard await budget.tryAcquire(cap * 4) else { await connection.close(); return }
        guard !shuttingDown else { await budget.release(cap * 4); await connection.close(); return }
        await connection.setMaximumFrameLength(cap)
        guard !shuttingDown else { await budget.release(cap * 4); await connection.close(); return }
        let key = UUID()
        session.peers[key] = ActivePeer(connection: connection, endpoint: endpoint, availability: PieceBitset(count: session.wanted.count))
        session.peers[key]?.receiveReservation = cap * 4
        session.peers[key]?.isOutbound = isOutbound
        do {
        try await connection.send(.bitfield(session.record.verified.bytes))
        if handshake.supportsExtensions {
            try await connection.send(.extended(id: 0, payload: PeerExtensions.extendedHandshake(metadataSize: session.record.metainfo.rawInfo.count, allowPEX: !session.record.metainfo.isPrivate)))
        }
        if !session.selectedComplete { try await connection.send(.interested) }
        session.peers[key]?.task = startBackgroundTask { engine in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    try await engine.handle(id, key: key, message: message)
                }
            } catch { /* Disconnect releases all outstanding reservations below. */ }
            await engine.disconnect(id, key: key)
        }
        } catch { await disconnect(id, key: key); throw error }
    }

    func disconnect(_ id: String, key: UUID) async {
        guard let session = sessions[id], let peer = session.peers.removeValue(forKey: key) else { return }
        session.knownEndpoints.remove(peer.endpoint)
        if [.downloading, .seeding].contains(session.snapshot.state), peer.endpoint.port > 0, !session.candidates.contains(peer.endpoint) { session.candidates.append(peer.endpoint) }
        peer.task?.cancel()
        peer.pumpTask?.cancel()
        peer.pexTask?.cancel()
        for request in peer.pending.keys {
            session.pieceWork[request.piece]?.requested.remove(request.begin)
            await budget.release(request.length)
        }
        await peer.connection.close()
        await budget.release(peer.receiveReservation)
    }

    func handle(_ id: String, key: UUID, message: PeerMessage) async throws {
        guard let session = sessions[id], var peer = session.peers[key] else { return }
        peer.lastMessage = Date(); session.peers[key] = peer
        switch message {
        case .bitfield(let data):
            session.peers[key]?.availability = try PieceBitset(count: session.wanted.count, bytes: data)
        case .have(let index):
            guard index >= 0 && index < session.wanted.count else { throw TorrentError.invalidMessage("Invalid have index") }
            session.peers[key]?.availability[index] = true
        case .choke:
            session.peers[key]?.choked = true
            let pending = session.peers[key]?.pending ?? [:]
            session.peers[key]?.pending.removeAll()
            for request in pending.keys {
                session.pieceWork[request.piece]?.requested.remove(request.begin)
                await budget.release(request.length)
            }
        case .unchoke: session.peers[key]?.choked = false
        case .interested:
            session.peers[key]?.interested = true
            try await peer.connection.send(.unchoke)
        case .notInterested: session.peers[key]?.interested = false
        case .piece(let index, let begin, let block):
            try await receiveBlock(id, key: key, index: index, begin: begin, block: block)
        case .request(let index, let begin, let length):
            try await upload(id, key: key, index: index, begin: begin, length: length)
        case .extended(let extensionID, let payload):
            if extensionID == 0 {
                let handshake = try PeerExtensions.parseHandshake(payload)
                session.peers[key]?.metadataID = handshake.metadataID
                session.peers[key]?.pexID = handshake.pexID
            } else if extensionID == 1 {
                let request = try PeerExtensions.parseMetadata(payload)
                if request.type == 0, let responseID = peer.metadataID {
                    let raw = session.record.metainfo.rawInfo
                    let start = request.piece * 16_384
                    if request.piece >= 0 && start >= 0 && start < raw.count {
                        let data = PeerExtensions.metadataData(piece: request.piece, totalSize: raw.count, block: raw.subdata(in: start..<min(start + 16_384, raw.count)))
                        try await peer.connection.send(.extended(id: responseID, payload: data))
                    } else { try await peer.connection.send(.extended(id: responseID, payload: PeerExtensions.metadataReject(piece: request.piece))) }
                }
            } else if extensionID == 2 && !session.record.metainfo.isPrivate {
                addCandidates(id, try PeerExtensions.parsePEX(payload))
            }
        case .cancel, .port, .keepAlive: break
        }
        queueRequests(id, key: key)
    }

    func queuePEX(_ id: String, key: UUID) {
        guard let session = sessions[id], !session.record.metainfo.isPrivate, let peer = session.peers[key],
              peer.pexID != nil, peer.pexTask == nil, Date().timeIntervalSince(peer.lastPEX) >= 60 else { return }
        session.peers[key]?.lastPEX = Date()
        session.peers[key]?.pexTask = startBackgroundTask { engine in
            await engine.sendPEX(id, key: key)
            engine.sessions[id]?.peers[key]?.pexTask = nil
        }
    }
    func sendPEX(_ id: String, key: UUID) async {
        guard let session = sessions[id], let peer = session.peers[key], let extensionID = peer.pexID else { return }
        let current = Set(session.peers.values.filter { $0.isOutbound && $0.endpoint != peer.endpoint }.map(\.endpoint).prefix(50))
        let added = Array(current.subtracting(peer.advertisedPeers)).prefix(50).map { $0 }
        let dropped = Array(peer.advertisedPeers.subtracting(current)).prefix(50).map { $0 }
        guard !added.isEmpty || !dropped.isEmpty else { return }
        do {
            try await peer.connection.send(.extended(id: extensionID, payload: PeerExtensions.encodePEX(added: added, dropped: dropped)))
            session.peers[key]?.advertisedPeers = current
        } catch { await disconnect(id, key: key) }
    }

    func queueRequests(_ id: String, key: UUID) {
        guard sessions[id]?.peers[key]?.pumpTask == nil else { return }
        sessions[id]?.peers[key]?.pumpTask = startBackgroundTask { engine in
            await engine.fillRequests(id, key: key)
            engine.sessions[id]?.peers[key]?.pumpTask = nil
        }
    }

    func fillRequests(_ id: String, key: UUID) async {
        guard let session = sessions[id], session.snapshot.state == .downloading, let initial = session.peers[key], !initial.pumping else { return }
        session.peers[key]?.pumping = true
        defer { session.peers[key]?.pumping = false }
        while let peer = session.peers[key], !peer.choked, peer.pending.count < 8 {
            guard let request = nextBlock(session, peer: peer) else { return }
            session.pieceWork[request.piece, default: PieceWork()].requested.insert(request.begin)
            do {
                guard await budget.tryAcquire(request.length) else { session.pieceWork[request.piece]?.requested.remove(request.begin); return }
                guard session.peers[key] != nil, session.snapshot.state == .downloading else {
                    await budget.release(request.length); session.pieceWork[request.piece]?.requested.remove(request.begin); return
                }
                session.peers[key]?.pending[request] = .distantFuture
                try await limiter.wait(bytes: request.length, upload: false)
                guard session.peers[key]?.pending[request] != nil else { return }
                session.peers[key]?.pending[request] = Date()
                try await peer.connection.send(.request(index: request.piece, begin: request.begin, length: request.length))
            } catch {
                // Registered pending reservations are returned by disconnect.
                if session.peers[key]?.pending[request] == nil { session.pieceWork[request.piece]?.requested.remove(request.begin) }
                await disconnect(id, key: key)
                return
            }
        }
    }

    func nextBlock(_ session: EngineSession, peer: ActivePeer) -> BlockRequest? {
        let meta = session.record.metainfo
        for index in session.pieceWork.keys.sorted() where peer.availability[index] {
            guard let work = session.pieceWork[index], !work.verifying else { continue }
            let pieceLength = meta.lengthOfPiece(index)
            let blockCount = (pieceLength + 16_383) / 16_384
            // A saturated piece has no holes; do not rescan thousands of received
            // blocks on every scheduling pass while waiting for its last response.
            guard work.received.count + work.requested.count < blockCount else { continue }
            var begin = work.nextBlockBegin
            for _ in 0..<blockCount {
                let next = begin + 16_384 < pieceLength ? begin + 16_384 : 0
                if !work.received.contains(begin) && !work.requested.contains(begin) {
                    session.pieceWork[index]?.nextBlockBegin = next
                    return BlockRequest(piece: index, begin: begin, length: min(16_384, pieceLength - begin))
                }
                // Wrap once to find holes left by cancelled or disconnected peers.
                begin = next
            }
        }
        // SIMD filters large availability bitmaps; rarity is evaluated on a bounded
        // candidate window to keep scheduling cheap on torrents with tiny pieces.
        var inFlight = PieceBitset(count: session.wanted.count)
        for index in session.pieceWork.keys { inFlight[index] = true }
        let candidates = PieceBitset.candidates(available: peer.availability, wanted: session.wanted, verified: session.record.verified, inFlight: inFlight)
        var best: Int?, rarity = Int.max, candidate = candidates.firstSetIndex(), inspected = 0
        while let index = candidate, inspected < 256 {
            let available = session.peers.values.reduce(0) { $0 + ($1.availability[index] ? 1 : 0) }
            if available < rarity { best = index; rarity = available }
            if profile(for: session) == .hdd || (profile(for: session) == .automatic && session.automaticHDD) { break }
            candidate = candidates.firstSetIndex(from: index + 1); inspected += 1
        }
        guard let index = best else { return nil }
        session.pieceWork[index] = PieceWork(nextBlockBegin: meta.lengthOfPiece(index) > 16_384 ? 16_384 : 0)
        return BlockRequest(piece: index, begin: 0, length: min(16_384, meta.lengthOfPiece(index)))
    }

    func receiveBlock(_ id: String, key: UUID, index: Int, begin: Int, block: Data) async throws {
        guard let session = sessions[id], let disk = session.disk else { return }
        let request = BlockRequest(piece: index, begin: begin, length: block.count)
        guard session.peers[key]?.pending.removeValue(forKey: request) != nil else { return }
        session.record.downloaded += Int64(block.count)
        session.snapshot.downloadedBytes = session.record.downloaded
        runStatistics.current.downloadedBytes += Int64(block.count)
        runStatistics.lifetimeDownloadedBytes += Int64(block.count)
        do {
            try await disk.write(offset: Int64(index) * Int64(session.record.metainfo.pieceLength) + Int64(begin), data: block)
            session.pieceWork[index]?.requested.remove(begin)
            session.pieceWork[index]?.received.insert(begin)
            await budget.release(block.count)
        } catch {
            await budget.release(block.count)
            session.snapshot.error = error.localizedDescription
            await stopSession(id, state: .failed)
            throw error
        }
        guard let work = session.pieceWork[index], !work.verifying,
              work.received.count == (session.record.metainfo.lengthOfPiece(index) + 16_383) / 16_384 else { return }
        session.pieceWork[index]?.verifying = true
        try await budget.acquire(65_536)
        let valid: Bool
        do { valid = try await disk.verifyPiece(index); await budget.release(65_536) }
        catch { await budget.release(65_536); session.pieceWork.removeValue(forKey: index); session.snapshot.error = error.localizedDescription; await stopSession(id, state: .failed); throw error }
        session.pieceWork.removeValue(forKey: index)
        if valid {
            session.record.verified[index] = true
            session.progressDirty = true
            for other in session.peers.values { try? await other.connection.send(.have(index)) }
            if session.record.verified.isComplete && !session.completedAnnounced {
                session.completedAnnounced = true
                startBackgroundTask { engine in await engine.announce(id, event: .completed) }
            }
            if session.selectedComplete {
                await refreshProgress(session); session.progressDirty = false
                for other in session.peers.values { try? await other.connection.send(.notInterested) }
                await schedule()
            }
        } else {
            await disconnect(id, key: key)
            session.snapshot.error = "A corrupt piece was discarded and will be downloaded again"
        }
    }

    func upload(_ id: String, key: UUID, index: Int, begin: Int, length: Int) async throws {
        guard let session = sessions[id], let peer = session.peers[key], let disk = session.disk,
              peer.interested, index >= 0, index < session.record.verified.count,
              session.record.verified[index], begin >= 0, length > 0, length <= 16_384,
              begin <= session.record.metainfo.lengthOfPiece(index) - length else { return }
        if session.selectedComplete && session.ratioReached { return }
        try await budget.acquire(length)
        do {
            try await limiter.wait(bytes: length, upload: true)
            let block = try await disk.read(offset: Int64(index) * Int64(session.record.metainfo.pieceLength) + Int64(begin), length: length)
            try await peer.connection.send(.piece(index: index, begin: begin, block: block))
            session.record.uploaded += Int64(length)
            runStatistics.current.uploadedBytes += Int64(length)
            runStatistics.lifetimeUploadedBytes += Int64(length)
            session.snapshot.uploadedBytes = session.record.uploaded
            await budget.release(length)
        } catch { await budget.release(length); throw error }
    }
}
