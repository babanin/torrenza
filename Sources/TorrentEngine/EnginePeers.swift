import Foundation
import Network
import TorrentCore
import TorrentWire

extension TorrentEngine {
    func disconnect(_ id: String, key: UUID) async {
        guard let session = sessions[id], let peer = session.peers.removeValue(forKey: key) else { return }
        session.removePeerAvailability(peer)
        session.knownEndpoints.remove(peer.endpoint)
        if [.downloading, .seeding].contains(session.snapshot.state), peer.endpoint.port > 0, !session.candidates.contains(peer.endpoint) { session.candidates.append(peer.endpoint) }
        peer.task?.cancel()
        peer.pumpTask?.cancel()
        peer.pexTask?.cancel()
        peer.announcementTask?.cancel()
        peer.uploadTask?.cancel()
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
            session.replacePeerAvailability(key: key, availability: try PieceBitset(count: session.wanted.count, bytes: data))
        case .have(let index):
            guard index >= 0 && index < session.wanted.count else { throw TorrentError.invalidMessage("Invalid have index") }
            session.recordPeerHave(key: key, index: index)
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
            queueUpload(id, key: key, request: BlockRequest(piece: index, begin: begin, length: length))
        case .extended(let extensionID, let payload):
            if extensionID == 0 {
                let handshake = try PeerExtensions.parseHandshake(payload)
                session.peers[key]?.remoteRequestQueueLimit = handshake.requestQueueLimit
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
        case .cancel(let index, let begin, let length):
            session.peers[key]?.uploadQueue.removeAll { $0 == BlockRequest(piece: index, begin: begin, length: length) }
        case .port, .keepAlive: break
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
        let generation = session.generation
        while !Task.isCancelled, sessions[id] === session, session.generation == generation,
              let peer = session.peers[key], !peer.choked,
              peer.pending.count < min(configuration.downloadRequestWindow, peer.remoteRequestQueueLimit ?? configuration.downloadRequestWindow) {
            guard let request = nextBlock(session, peer: peer) else { return }
            session.pieceWork[request.piece, default: PieceWork()].requested.insert(request.begin)
            do {
                guard await budget.tryAcquire(request.length) else {
                    if session.generation == generation { session.pieceWork[request.piece]?.requested.remove(request.begin) }
                    return
                }
                guard !Task.isCancelled, sessions[id] === session, session.generation == generation, session.peers[key] != nil, session.snapshot.state == .downloading else {
                    await budget.release(request.length)
                    if session.generation == generation { session.pieceWork[request.piece]?.requested.remove(request.begin) }
                    return
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

    func receiveBlock(_ id: String, key: UUID, index: Int, begin: Int, block: Data) async throws {
        guard let session = sessions[id], let disk = session.disk else { return }
        let generation = session.generation
        guard session.record.quarantineError == nil else { return }
        let request = BlockRequest(piece: index, begin: begin, length: block.count)
        guard session.peers[key]?.pending.removeValue(forKey: request) != nil else { return }
        session.record.downloaded += Int64(block.count)
        session.snapshot.downloadedBytes = session.record.downloaded
        runStatistics.current.downloadedBytes += Int64(block.count)
        runStatistics.lifetimeDownloadedBytes += Int64(block.count)
        do {
            try await disk.write(offset: Int64(index) * Int64(session.record.metainfo.pieceLength) + Int64(begin), data: block)
            if sessions[id] === session, session.generation == generation, session.record.quarantineError == nil {
                session.pieceWork[index]?.requested.remove(begin)
                session.pieceWork[index]?.received.insert(begin)
            }
            await budget.release(block.count)
        } catch {
            await budget.release(block.count)
            if !(error is CancellationError), sessions[id] === session, session.generation == generation { await quarantine(id, error: error) }
            throw error
        }
        guard sessions[id] === session, session.generation == generation, session.record.quarantineError == nil,
              let work = session.pieceWork[index], !work.verifying,
              work.received.count == (session.record.metainfo.lengthOfPiece(index) + 16_383) / 16_384 else { return }
        session.pieceWork[index]?.verifying = true
        session.verificationQueue.append((index, key))
        startVerificationWorker(id, session: session)
    }

    func startVerificationWorker(_ id: String, session: EngineSession) {
        guard session.verificationTask == nil, !session.verificationQueue.isEmpty, !shuttingDown else { return }
        let workerID = UUID()
        let generation = session.generation
        session.verificationWorkerID = workerID
        session.verificationTask = startBackgroundTask { engine in
            guard let current = engine.sessions[id], current.generation == generation, current.verificationWorkerID == workerID else { return }
            await engine.verifyCompletedPieces(id, session: current, generation: generation, workerID: workerID)
        }
    }

    func verifyCompletedPieces(_ id: String, session: EngineSession, generation: Int, workerID: UUID) async {
        defer {
            if session.verificationWorkerID == workerID {
                session.verificationTask = nil
                session.verificationWorkerID = nil
            }
        }
        while !Task.isCancelled, sessions[id] === session, session.generation == generation,
              session.record.quarantineError == nil, !session.verificationQueue.isEmpty, let disk = session.disk {
            let completion = session.verificationQueue.removeFirst()
            let valid: Bool
            do {
                valid = try await verifyPiece(disk, index: completion.piece)
            } catch {
                guard sessions[id] === session, session.generation == generation else { return }
                if !(error is CancellationError) {
                    // Quarantine drains workers. Detach this failing worker first so
                    // stopSession cannot await the very task calling it.
                    session.verificationTask = nil
                    session.verificationWorkerID = nil
                    await quarantine(id, error: error)
                }
                return
            }
            guard !Task.isCancelled, sessions[id] === session, session.generation == generation,
                  session.record.quarantineError == nil else { return }
            session.removePieceWork(completion.piece)
            if valid {
                session.record.verified[completion.piece] = true
                session.progressDirty = true
                for key in session.peers.keys { queueAnnouncement(id, key: key, have: completion.piece) }
                if session.record.verified.isComplete && !session.completedAnnounced {
                    session.completedAnnounced = true
                    startBackgroundTask { engine in await engine.announce(id, event: .completed) }
                }
                if session.selectedComplete {
                    await refreshProgress(session)
                    session.progressDirty = false
                    for key in session.peers.keys { queueAnnouncement(id, key: key, notInterested: true) }
                    // Scheduling can stop this transfer at its seed ratio. Run it
                    // outside the worker so stopSession can safely drain us.
                    startBackgroundTask { engine in await engine.schedule() }
                }
            } else {
                await disconnect(id, key: completion.source)
                guard sessions[id] === session, session.generation == generation, session.record.quarantineError == nil else { return }
                session.snapshot.error = "A corrupt piece was discarded and will be downloaded again"
            }
            for key in session.peers.keys { queueRequests(id, key: key) }
        }
    }

    /// One writer per peer coalesces duplicate HAVEs in a fixed-size bitmap.
    /// Registration's four-frame reservation includes this bitmap. Bitfields are
    /// sent only during the initial handshake, as required by BEP 3.
    func queueAnnouncement(_ id: String, key: UUID, have: Int? = nil, notInterested: Bool = false) {
        guard let session = sessions[id], session.peers[key] != nil else { return }
        if let have, (0..<session.wanted.count).contains(have) {
            if session.peers[key]?.pendingHaves == nil {
                session.peers[key]?.pendingHaves = PieceBitset(count: session.wanted.count)
            }
            session.peers[key]?.pendingHaves?[have] = true
        }
        if notInterested { session.peers[key]?.pendingNotInterested = true }
        guard session.peers[key]?.announcementTask == nil else { return }
        let generation = session.generation
        session.peers[key]?.announcementTask = startBackgroundTask { engine in
            guard let current = engine.sessions[id], current.generation == generation else { return }
            await engine.sendAnnouncements(id, key: key, session: current, generation: generation)
        }
    }

    func sendAnnouncements(_ id: String, key: UUID, session: EngineSession, generation: Int) async {
        defer { session.peers[key]?.announcementTask = nil }
        while !Task.isCancelled, sessions[id] === session, session.generation == generation,
              let connection = session.peers[key]?.connection {
            let message: PeerMessage
            let cursor = session.peers[key]?.announcementCursor ?? 0
            if let index = session.peers[key]?.pendingHaves?.firstSetIndex(from: cursor) ?? session.peers[key]?.pendingHaves?.firstSetIndex() {
                session.peers[key]?.pendingHaves?[index] = false
                session.peers[key]?.announcementCursor = index + 1
                message = .have(index)
            } else if session.peers[key]?.pendingNotInterested == true {
                session.peers[key]?.pendingNotInterested = false
                message = .notInterested
            } else { return }
            do { try await connection.send(message) }
            catch { await disconnect(id, key: key); return }
        }
    }

    /// Keep upload backpressure outside the receive loop, which must continue
    /// consuming downloaded blocks to release shared payload reservations.
    func queueUpload(_ id: String, key: UUID, request: BlockRequest) {
        guard let session = sessions[id], let peer = session.peers[key],
              peer.uploadQueue.count + (peer.activeUpload == nil ? 0 : 1) < 32,
              peer.activeUpload != request, !peer.uploadQueue.contains(request),
              peer.interested, request.piece >= 0, request.piece < session.record.verified.count,
              session.record.verified[request.piece], request.begin >= 0,
              request.length > 0, request.length <= 16_384,
              request.begin <= session.record.metainfo.lengthOfPiece(request.piece) - request.length else { return }
        session.peers[key]?.uploadQueue.append(request)
        guard peer.uploadTask == nil else { return }
        let generation = session.generation
        session.peers[key]?.uploadTask = startBackgroundTask { engine in
            await engine.sendQueuedUploads(id, key: key, generation: generation)
        }
    }

    func sendQueuedUploads(_ id: String, key: UUID, generation: Int) async {
        guard let session = sessions[id], session.generation == generation else { return }
        defer {
            session.peers[key]?.activeUpload = nil
            session.peers[key]?.uploadTask = nil
        }
        while !Task.isCancelled, sessions[id] === session, session.generation == generation,
              let request = session.peers[key]?.uploadQueue.first {
            session.peers[key]?.uploadQueue.removeFirst()
            session.peers[key]?.activeUpload = request
            do { try await upload(id, key: key, index: request.piece, begin: request.begin, length: request.length) }
            catch { await disconnect(id, key: key); return }
            session.peers[key]?.activeUpload = nil
        }
    }

    func upload(_ id: String, key: UUID, index: Int, begin: Int, length: Int) async throws {
        guard let session = sessions[id], let peer = session.peers[key], let disk = session.disk,
              peer.interested, index >= 0, index < session.record.verified.count,
              session.record.verified[index], begin >= 0, length > 0, length <= 16_384,
              begin <= session.record.metainfo.lengthOfPiece(index) - length else { return }
        if session.selectedComplete && session.ratioReached { return }
        let generation = session.generation
        try await budget.acquire(length)
        do {
            try await limiter.wait(bytes: length, upload: true)
            let block: Data
            do { block = try await disk.read(offset: Int64(index) * Int64(session.record.metainfo.pieceLength) + Int64(begin), length: length) }
            catch {
                if !(error is CancellationError), sessions[id] === session, session.generation == generation { await quarantine(id, error: error) }
                throw error
            }
            guard !Task.isCancelled, sessions[id] === session, session.generation == generation, session.record.quarantineError == nil, session.peers[key] != nil else { await budget.release(length); return }
            try await peer.connection.send(.piece(index: index, begin: begin, block: block))
            session.recordUploadedBlock(offset: Int64(index) * Int64(session.record.metainfo.pieceLength) + Int64(begin), length: length)
            runStatistics.current.uploadedBytes += Int64(length)
            runStatistics.lifetimeUploadedBytes += Int64(length)
            session.snapshot.uploadedBytes = session.record.uploaded
            await budget.release(length)
        } catch { await budget.release(length); throw error }
    }
}
