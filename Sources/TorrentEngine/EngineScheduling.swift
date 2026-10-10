import Foundation
import Network
import TorrentCore
import TorrentWire
import TorrentStorage

extension TorrentEngine {
    public func listenPort() -> UInt16 { listeningPort }
    var constrainedPower: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    }
    var effectivePeerLimit: Int { constrainedPower ? min(16, configuration.maxPeers) : configuration.maxPeers }

    func profile(for session: EngineSession) -> StorageProfile {
        configuration.destinationProfiles[session.record.destination.standardizedFileURL.path] ?? configuration.storageProfile
    }

    var needsPeriodicUpdates: Bool {
        !resolving.isEmpty || sessions.values.contains {
            [.downloading, .seeding, .checking].contains($0.snapshot.state)
        }
    }

    func publishSnapshots() {
        guard !observers.isEmpty else { return }
        let snapshots = currentSnapshots()
        for continuation in observers.values { continuation.yield(snapshots) }
    }

    /// Paused/completed libraries are event-driven: no repeating wakeups or
    /// periodic checkpoints until transfer work resumes.
    func updateActivity() {
        publishSnapshots()
        if needsPeriodicUpdates && !shuttingDown { startTicker() }
        else { ticker?.cancel(); ticker = nil }
    }

    func startTicker() {
        guard ticker == nil, !shuttingDown, !activating, needsPeriodicUpdates else { return }
        lastCheckpoint = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                await self?.tick()
            }
        }
    }

    func tick() async {
        guard !shuttingDown else { return }
        await rebalanceConnections()
        for id in Array(sessions.keys) {
            guard let session = sessions[id] else { continue }
            let now = Date(), elapsed = now.timeIntervalSince(session.lastRate)
            if elapsed >= 0.5 {
                session.snapshot.downloadRate = Double(session.record.downloaded - session.previousDownloaded) / elapsed
                session.snapshot.uploadRate = Double(session.record.uploaded - session.previousUploaded) / elapsed
                session.previousDownloaded = session.record.downloaded; session.previousUploaded = session.record.uploaded; session.lastRate = now
            }
            if session.progressDirty { await refreshProgress(session); session.progressDirty = false }
            session.snapshot.downloadedBytes = session.record.downloaded
            session.snapshot.uploadedBytes = session.record.uploaded
            session.snapshot.swarm.connectedPeers = session.peers.count
            session.snapshot.swarm.connectedSeeds = session.picker.seedCount
            if [.downloading, .seeding].contains(session.snapshot.state) {
                if session.selectedComplete && session.ratioReached { await stopSession(id, state: .completed); continue }
                if now >= session.nextAnnounce && !session.discoveryInProgress {
                    session.discoveryInProgress = true
                    session.task = startBackgroundTask { engine in await engine.discover(id) }
                }
                for (key, peer) in session.peers {
                    if now.timeIntervalSince(peer.lastMessage) > 180 || peer.pending.values.contains(where: { now.timeIntervalSince($0) > 45 }) {
                        await disconnect(id, key: key)
                    } else { queueRequests(id, key: key); queuePEX(id, key: key) }
                }
                connectCandidates(id)
            }
        }
        if Date().timeIntervalSince(lastCheckpoint) >= 30 {
            lastCheckpoint = Date()
            do { try await checkpoint() }
            catch is CancellationError { /* Pausing can stop this tick during a checkpoint. */ }
            catch {
                for session in sessions.values where session.record.quarantineError == nil { session.snapshot.error = "Could not save resume state: \(error.localizedDescription)" }
            }
        }
        await schedule()
    }

    func currentSnapshots() -> [TransferSnapshot] {
        (sessions.values.map(\.snapshot) + Array(resolving.values) + (libraryError.map { [$0] } ?? [])).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func checkpoint(cleanShutdown: Bool = false) async throws {
        await acquireSaveGate()
        defer { releaseSaveGate() }
        guard libraryError == nil else { throw TorrentError.storage("Unreadable saved state was preserved") }
        for session in sessions.values {
            do {
                try await session.disk?.flush()
                if cleanShutdown, let disk = session.disk { session.record.diskSignatures = try await disk.signatures() }
            } catch is CancellationError { throw CancellationError() }
            catch { await quarantine(session.record.metainfo.id, error: error, persist: false) }
        }
        let contacts = await dht?.contactsSnapshot()
        try await persistence.save(EngineArchive(cleanShutdown: cleanShutdown, settings: configuration, records: sessions.values.map(\.record)), contacts: contacts, statistics: statisticsLoaded ? runStatistics : nil)
    }

    func updateOwnership(_ session: EngineSession) async throws {
        guard let disk = session.disk else { return }
        var owned = Dictionary(uniqueKeysWithValues: (session.record.ownedSignatures ?? []).map { ($0.path, $0) })
        for signature in try await disk.signatures() { owned[signature.path] = signature }
        session.record.ownedSignatures = owned.values.sorted { $0.path < $1.path }
    }

    func openDisk(_ session: EngineSession, allowNewFiles: Bool = false) async throws {
        guard !session.record.selectedFiles.isEmpty else { return }
        guard session.disk == nil else { return }
        guard FileManager.default.fileExists(atPath: session.record.destination.path) else { throw TorrentError.storage("Destination volume or folder is unavailable") }
        if let expected = session.record.volumeUUID {
            let current = try session.record.destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard current == expected else { throw TorrentError.storage("The original destination volume is unavailable") }
        }
        if let owned = session.record.ownedSignatures {
            let selectedPaths = Set(session.record.metainfo.files.filter { session.record.selectedFiles.contains($0.index) }.map { $0.path.joined(separator: "/") })
            try await TorrentDisk.validateOwnedFiles(destination: session.record.destination, signatures: owned.filter { selectedPaths.contains($0.path) })
        }
        let generation = session.generation
        let disk = try TorrentDisk(metainfo: session.record.metainfo, destination: session.record.destination, selectedFiles: session.record.selectedFiles, allowExisting: true, requireExistingPayload: !allowNewFiles, requireExistingSidecars: !allowNewFiles)
        try await disk.prepare()
        guard session.generation == generation, session.record.quarantineError == nil else {
            await disk.close()
            throw CancellationError()
        }
        session.disk = disk
    }

    func verifyAll(_ id: String) async {
        guard let session = sessions[id], !session.busy else { return }
        session.busy = true
        let generation = session.generation
        session.snapshot.state = .checking
        startTicker()
        defer { session.busy = false }
        do {
            try await openDisk(session)
            guard let disk = session.disk else { return }
            session.record.verified = PieceBitset(count: session.record.metainfo.pieceHashes.count)
            for index in 0..<session.wanted.count where session.wanted[index] {
                guard session.generation == generation, sessions[id] != nil else { return }
                try Task.checkCancellation()
                let valid = try await verifyPiece(disk, index: index)
                guard session.generation == generation, session.record.quarantineError == nil else { return }
                session.record.verified[index] = valid
            }
            await refreshProgress(session)
        } catch is CancellationError { /* An explicit pause or shutdown cancels checking. */ }
        catch { await quarantine(id, error: error) }
    }

    func refreshProgress(_ session: EngineSession) async {
        session.snapshot.files = TorrentDisk.fileSnapshots(metainfo: session.record.metainfo, selectedFiles: session.record.selectedFiles, verified: session.record.verified)
        for index in session.snapshot.files.indices {
            session.snapshot.files[index].uploadedBytes = session.record.fileUploadedBytes?[session.snapshot.files[index].id] ?? 0
        }
        session.snapshot.selectedBytes = session.snapshot.files.filter(\.selected).reduce(0) { $0 + $1.file.length }
        session.snapshot.completedBytes = session.snapshot.files.filter(\.selected).reduce(0) { $0 + $1.verifiedBytes }
    }

    func schedule() async {
        defer { updateActivity() }
        guard !shuttingDown, !activating, suspended.isEmpty else { return }
        if needsDirtyCheckpoint {
            do { try await checkpoint(); needsDirtyCheckpoint = false }
            catch {
                for session in sessions.values { session.snapshot.state = .failed; session.snapshot.error = "Could not safely resume: \(error.localizedDescription)" }
                return
            }
        }
        var downloads = 0, seeds = 0
        var hddVolumes: Set<String> = []
        for id in sessions.keys.sorted() {
            guard let session = sessions[id], session.record.wantedRunning, !session.busy, session.record.quarantineError == nil,
                  !session.record.selectedFiles.isEmpty,
                  ![.failed, .unavailable, .checking].contains(session.snapshot.state) else { continue }
            if session.selectedComplete && session.ratioReached {
                if session.snapshot.state != .completed { await stopSession(id, state: .completed) }
                continue
            }
            let seed = session.selectedComplete
            let volume = session.volumeKey
            let storageProfile = profile(for: session)
            let usesHDDProfile = storageProfile == .hdd || (storageProfile == .automatic && session.automaticHDD)
            let hddBlocked = !seed && usesHDDProfile && hddVolumes.contains(volume)
            let allowed = seed ? seeds < configuration.maxSeeds : downloads < (constrainedPower ? 1 : configuration.maxDownloads) && !hddBlocked
            if !allowed {
                if [.downloading, .seeding].contains(session.snapshot.state) { await stopSession(id, state: .queued) }
                else { session.snapshot.state = .queued }
                continue
            }
            if seed { seeds += 1 } else { downloads += 1; if usesHDDProfile { hddVolumes.insert(volume) } }
            if ![.downloading, .seeding].contains(session.snapshot.state) {
                let generation = session.generation
                do { try await openDisk(session) }
                catch is CancellationError { return }
                catch { await quarantine(id, error: error); continue }
                do {
                    try await ensureListener()
                    guard session.generation == generation, session.record.wantedRunning, session.record.quarantineError == nil else { continue }
                    session.snapshot.state = seed ? .seeding : .downloading
                    session.nextAnnounce = .distantPast
                } catch {
                    if session.record.quarantineError == nil {
                        session.snapshot.state = .failed
                        session.snapshot.error = error.localizedDescription
                    }
                }
            } else { session.snapshot.state = seed ? .seeding : .downloading }
        }
    }

    func stopSession(_ id: String, state: TransferState, flushDisk: Bool = true) async {
        guard let session = sessions[id] else { return }
        session.snapshot.state = state
        session.generation += 1
        session.discoveryInProgress = false
        session.discoveryGeneration = nil
        let verificationTask = session.verificationTask
        verificationTask?.cancel()
        session.verificationTask = nil
        session.verificationWorkerID = nil
        session.verificationQueue.removeAll()
        session.task?.cancel(); session.task = nil
        for task in session.connectionTasks.values { task.cancel() }
        session.connectionTasks.removeAll()
        for key in Array(session.peers.keys) { await disconnect(id, key: key) }
        await verificationTask?.value
        session.clearPieceWork()
        session.candidates.removeAll(); session.knownEndpoints.removeAll(); session.lastAttempt.removeAll()
        session.snapshot.downloadRate = 0; session.snapshot.uploadRate = 0
        if session.startedAnnounced {
            session.startedAnnounced = false
            if !shuttingDown {
                startBackgroundTask { engine in await engine.announce(id, event: .stopped) }
            }
        }
        if flushDisk {
            do { try await session.disk?.flush() }
            catch is CancellationError { }
            catch { await quarantine(id, error: error) }
        }
    }

    /// A payload I/O failure belongs to the torrent, not to a single peer.
    /// Keep it stopped across launches until the user explicitly retries it.
    func quarantine(_ id: String, error: Error, persist: Bool = true) async {
        guard let session = sessions[id] else { return }
        let message = session.record.quarantineError ?? error.localizedDescription
        session.record.quarantineError = message
        session.record.wantedRunning = false
        session.snapshot.error = message
        await stopSession(id, state: .failed, flushDisk: false)
        await session.disk?.close()
        session.disk = nil
        session.snapshot.error = message
        session.snapshot.swarm.connectedPeers = 0
        session.snapshot.swarm.connectedSeeds = 0
        if persist {
            await acquireSaveGate()
            try? await persistence.saveQuarantine(session.record)
            releaseSaveGate()
        }
        updateActivity()
    }

    public func volumesChanged() async {
        guard !shuttingDown else { return }
        for id in Array(sessions.keys) {
            guard let session = sessions[id], !session.record.selectedFiles.isEmpty, session.record.quarantineError == nil else { continue }
            if !FileManager.default.fileExists(atPath: session.record.destination.path) {
                await quarantine(id, error: TorrentError.storage("Destination volume is unavailable"))
            }
        }
        await schedule()
    }

    func ensureListener() async throws {
        guard !shuttingDown else { throw CancellationError() }
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.enqueueIncoming(connection) } }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue { Task { await self?.setListeningPort(port) } }
        }
        listener.start(queue: DispatchQueue(label: "app.torrenza.listener", qos: .utility))
        for _ in 0..<100 {
            guard !shuttingDown else { throw CancellationError() }
            if listeningPort != 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TorrentError.network("Could not start the incoming peer listener")
    }
    func enqueueIncoming(_ connection: NWConnection) {
        guard let admission = reserveConnection(for: nil) else { connection.cancel(); return }
        connectionAdmissions[admission]?.task = startBackgroundTask { engine in await engine.accept(connection, admission: admission) }
    }
    func setListeningPort(_ port: UInt16) { if !shuttingDown { listeningPort = port } }

    func ensureDHT() async throws -> DHTClient {
        guard !shuttingDown else { throw CancellationError() }
        if let dht { return dht }
        let contacts = try await persistence.loadDHTContacts()
        guard !shuttingDown else { throw CancellationError() }
        // Another torrent may have initialized the shared node while storage
        // was loading its contacts.
        if let dht { return dht }
        let client = DHTClient(bootstrapNodes: configuration.bootstrapNodes, persistedContacts: contacts)
        dht = client
        try await client.start()
        return client
    }

    func discover(_ id: String) async {
        guard let session = sessions[id], !shuttingDown, !Task.isCancelled,
              [.downloading, .seeding].contains(session.snapshot.state) else { return }
        let identity = ObjectIdentifier(session), generation = session.generation
        session.discoveryGeneration = generation
        defer {
            if sessions[id] === session, session.discoveryGeneration == generation {
                session.discoveryInProgress = false
                session.discoveryGeneration = nil
            }
        }
        let event: TrackerEvent = session.startedAnnounced ? .none : .started
        let isPrivate = session.record.metainfo.isPrivate
        // Keep tracker failover/interval policy, but let public discovery and
        // candidate admission proceed while a tracker is waiting on the network.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.announce(id, event: event) }
            if !isPrivate {
                group.addTask { await self.discoverDHT(id, identity: identity, generation: generation) }
            }
        }
    }

    private func discoverDHT(_ id: String, identity: ObjectIdentifier, generation: Int) async {
        guard let session = sessions[id], ObjectIdentifier(session) == identity,
              session.generation == generation, !shuttingDown, !Task.isCancelled else { return }
        do {
            let client = try await ensureDHT()
            guard session.generation == generation, !shuttingDown, !Task.isCancelled else { return }
            _ = try await client.peers(infoHash: session.record.metainfo.infoHash) { endpoints in
                await self.admitDiscoveredCandidates(id, identity: identity, generation: generation, endpoints: endpoints)
            }
            guard sessions[id] === session, session.generation == generation,
                  !shuttingDown, !Task.isCancelled else { return }
            await client.announce(infoHash: session.record.metainfo.infoHash, port: listeningPort)
        } catch {
            if sessions[id] === session, session.generation == generation, !Task.isCancelled,
               session.record.quarantineError == nil, session.candidates.isEmpty, session.peers.isEmpty {
                session.snapshot.error = error.localizedDescription
            }
        }
    }

    private func admitDiscoveredCandidates(_ id: String, identity: ObjectIdentifier, generation: Int, endpoints: [PeerEndpoint]) {
        guard let session = sessions[id], ObjectIdentifier(session) == identity,
              session.generation == generation, !shuttingDown, !Task.isCancelled,
              session.record.quarantineError == nil,
              [.downloading, .seeding].contains(session.snapshot.state) else { return }
        addCandidates(id, endpoints)
        connectCandidates(id)
    }

    func trackerPeerRequestCount(for id: String) -> Int {
        let active = max(1, sessions.values.filter { [.downloading, .seeding].contains($0.snapshot.state) }.count)
        let fairShare = (effectivePeerLimit + active - 1) / active
        let held = (sessions[id]?.peers.count ?? 0) + handshakes(for: id)
        // A torrent below its fair share needs candidates even when another
        // torrent has borrowed the currently free connection capacity.
        return min(200, max(0, effectivePeerLimit - totalPeers, fairShare - held))
    }

    func announce(_ id: String, event: TrackerEvent) async {
        guard let session = sessions[id] else { return }
        let meta = session.record.metainfo
        let generation = session.generation
        let verified = (0..<meta.pieceHashes.count).filter { session.record.verified[$0] }.reduce(Int64(0)) { $0 + Int64(meta.lengthOfPiece($1)) }
        let request = TrackerRequest(infoHash: meta.infoHash, peerID: peerID, port: listeningPort, uploaded: session.record.uploaded, downloaded: session.record.downloaded, left: max(0, meta.totalLength - verified), event: event, numWant: event == .stopped ? 0 : trackerPeerRequestCount(for: id))
        let client = TrackerClient()
        for url in meta.trackerTiers.flatMap({ $0 }) {
            guard !shuttingDown, !Task.isCancelled, sessions[id] === session,
                  event == .stopped || session.generation == generation else { return }
            if session.snapshot.swarm.tracker != url.absoluteString {
                session.snapshot.swarm.reportedSeeds = nil; session.snapshot.swarm.reportedPeers = nil; session.snapshot.swarm.reportedAt = nil
            }
            do {
                let response = try await client.announce(url: url, request: request)
                guard !shuttingDown, !Task.isCancelled, sessions[id] === session,
                      event == .stopped || session.generation == generation else { return }
                if event == .stopped { return }
                if meta.isPrivate, let previous = session.snapshot.swarm.tracker, previous != url.absoluteString {
                    session.generation += 1
                    let switchGeneration = session.generation
                    let verificationTask = session.verificationTask
                    verificationTask?.cancel()
                    session.verificationTask = nil
                    session.verificationWorkerID = nil
                    session.verificationQueue.removeAll()
                    for task in session.connectionTasks.values { task.cancel() }
                    session.connectionTasks.removeAll()
                    for key in Array(session.peers.keys) { await disconnect(id, key: key) }
                    await verificationTask?.value
                    guard sessions[id] === session, session.generation == switchGeneration,
                          !shuttingDown, !Task.isCancelled else { return }
                    session.clearPieceWork()
                    session.candidates.removeAll(); session.knownEndpoints.removeAll(); session.lastAttempt.removeAll()
                }
                guard session.record.quarantineError == nil else { return }
                session.snapshot.swarm.tracker = url.absoluteString
                session.snapshot.swarm.reportedSeeds = response.seeders
                if let seeds = response.seeders, let leechers = response.leechers { session.snapshot.swarm.reportedPeers = seeds + leechers }
                else { session.snapshot.swarm.reportedPeers = nil }
                session.snapshot.swarm.reportedAt = Date()
                session.snapshot.swarm.announceInterval = max(60, response.interval)
                session.nextAnnounce = Date().addingTimeInterval(max(60, response.interval))
                session.startedAnnounced = true
                session.snapshot.error = nil
                addCandidates(id, response.peers)
                connectCandidates(id)
                return
            } catch {
                if sessions[id] === session, session.generation == generation, !Task.isCancelled,
                   session.record.quarantineError == nil { session.snapshot.error = "Tracker: \(error.localizedDescription)" }
            }
        }
        if sessions[id] === session, session.generation == generation, !Task.isCancelled {
            session.nextAnnounce = Date().addingTimeInterval(60)
        }
    }

    func addCandidates(_ id: String, _ endpoints: [PeerEndpoint]) {
        guard let session = sessions[id] else { return }
        for endpoint in endpoints where session.knownEndpoints.count < 2_000 {
            if session.knownEndpoints.insert(endpoint).inserted { session.candidates.append(endpoint) }
        }
    }
}
