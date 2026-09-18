import Foundation
import TorrentCore
import TorrentWire

extension TorrentEngine {
    public func resolve(magnet: URL) async throws -> TorrentMetainfo {
        guard !shuttingDown else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await self.resolveMetadata(magnet: magnet) }
        resolutionTasks[id] = task
        defer { resolutionTasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func resolveMetadata(magnet: URL) async throws -> TorrentMetainfo {
        let link = try MagnetParser.parse(magnet)
        let resolvingID = "resolving-" + link.infoHash.hexString
        resolving[resolvingID] = TransferSnapshot(id: resolvingID, name: link.displayName ?? link.infoHash.hexString, state: .resolving)
        updateActivity()
        defer { resolving.removeValue(forKey: resolvingID); updateActivity() }
        try await ensureListener()
        var endpoints = link.peers
        let tracker = TrackerClient()
        let request = TrackerRequest(infoHash: link.infoHash, peerID: peerID, port: listeningPort, left: 1, event: .started)
        // Tracker discovery runs concurrently so one unresponsive endpoint does
        // not block other trackers or DHT for the entire metadata phase.
        let discovered = await withTaskGroup(of: [PeerEndpoint].self) { group in
            for url in link.trackers.prefix(8) {
                group.addTask { (try? await tracker.announce(url: url, request: request).peers) ?? [] }
            }
            if let client = try? await ensureDHT() {
                group.addTask { (try? await client.peers(infoHash: link.infoHash)) ?? [] }
            }
            var peers: [PeerEndpoint] = []
            for await found in group { peers.append(contentsOf: found) }
            return peers
        }
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        endpoints.append(contentsOf: discovered)
        endpoints = Array(Set(endpoints)).prefix(60).map { $0 }
        guard !endpoints.isEmpty else { throw TorrentError.network("No peers found for this magnet. Try again when peers are available, or open its .torrent file.") }
        let identity = peerID, budget = budget
        let result = try await withThrowingTaskGroup(of: Result<TorrentMetainfo, TorrentError>.self) { group in
            var iterator = endpoints.makeIterator()
            for _ in 0..<min(4, endpoints.count) {
                if let endpoint = iterator.next() {
                    group.addTask {
                        do { return .success(try await Self.metadata(from: endpoint, link: link, peerID: identity, budget: budget)) }
                        catch { return .failure(.network(error.localizedDescription)) }
                    }
                }
            }
            var lastError = "No peer answered"
            while let result = try await group.next() {
                switch result {
                case .success(let metainfo): group.cancelAll(); return metainfo
                case .failure(let error): lastError = error.localizedDescription
                }
                try Task.checkCancellation()
                if let endpoint = iterator.next() {
                    group.addTask {
                        do { return .success(try await Self.metadata(from: endpoint, link: link, peerID: identity, budget: budget)) }
                        catch { return .failure(.network(error.localizedDescription)) }
                    }
                }
            }
            throw TorrentError.network("Could not resolve torrent metadata: \(lastError)")
        }
        if result.isPrivate { throw TorrentError.unsupported("This is a private torrent. Open its .torrent file to use tracker-only discovery.") }
        return result
    }

    nonisolated static func metadata(from endpoint: PeerEndpoint, link: MagnetLink, peerID: Data, budget: ResourceBudget) async throws -> TorrentMetainfo {
        let connection = try PeerConnection(endpoint: endpoint, maximumFrameLength: 32_768)
        guard await budget.tryAcquire(131_072) else { throw TorrentError.network("Metadata resolution is waiting for memory capacity; pause a transfer and retry") }
        var reservation = 131_072
        do {
            let handshake = try await connection.connect(infoHash: link.infoHash, peerID: peerID)
            guard handshake.supportsExtensions else { throw TorrentError.unsupported("Peer does not support metadata exchange") }
            try await connection.send(.extended(id: 0, payload: PeerExtensions.extendedHandshake()))
            var remoteID: UInt8?, size: Int?, blocks: [Int: Data] = [:], requested: Set<Int> = []
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                try Task.checkCancellation()
                let message = try await connection.receive()
                guard case .extended(let id, let payload) = message else { continue }
                if id == 0 {
                    let extensionHandshake = try PeerExtensions.parseHandshake(payload)
                    guard let metadataID = extensionHandshake.metadataID, let metadataSize = extensionHandshake.metadataSize,
                          metadataSize > 0, metadataSize <= 16 * 1024 * 1024 else { throw TorrentError.invalidMessage("Peer has no valid metadata size") }
                    if size == nil {
                        // Reserve space for chunks plus their final contiguous copy.
                        guard await budget.tryAcquire(metadataSize * 2) else { throw TorrentError.network("Metadata exceeds the currently available memory budget") }
                        reservation += metadataSize * 2
                        remoteID = metadataID; size = metadataSize
                    }
                } else if id == 1 {
                    let response = try PeerExtensions.parseMetadata(payload)
                    guard response.type != 2 else { throw TorrentError.network("Peer rejected metadata request") }
                    guard response.type == 1, let size, response.totalSize == size,
                          response.piece >= 0, requested.contains(response.piece), response.piece < (size + 16_383) / 16_384,
                          response.block.count == min(16_384, size - response.piece * 16_384) else { throw TorrentError.invalidMessage("Invalid metadata block") }
                    blocks[response.piece] = response.block
                }
                if let size, let remoteID {
                    let count = (size + 16_383) / 16_384
                    if blocks.count == count {
                        var raw = Data(capacity: size)
                        for index in 0..<count { raw.append(blocks[index]!) }
                        let meta = try MetainfoParser.parseInfo(raw, trackers: link.trackers)
                        guard meta.infoHash == link.infoHash else { throw TorrentError.invalidMetainfo("Magnet metadata hash does not match") }
                        await connection.close(); await budget.release(reservation)
                        return meta
                    }
                    for piece in 0..<count where !requested.contains(piece) && requested.count - blocks.count < 4 {
                        requested.insert(piece)
                        try await connection.send(.extended(id: remoteID, payload: PeerExtensions.metadataRequest(piece: piece)))
                    }
                }
            }
            throw TorrentError.network("Metadata exchange timed out")
        } catch {
            await connection.close()
            if reservation > 0 { await budget.release(reservation) }
            throw error
        }
    }
}
