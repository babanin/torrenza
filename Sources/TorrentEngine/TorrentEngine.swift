import Foundation
import Network
import TorrentCore
import TorrentWire
import TorrentStorage

struct BlockRequest: Hashable, Sendable {
    let piece: Int
    let begin: Int
    let length: Int
}

struct ActivePeer {
    let connection: PeerConnection
    let endpoint: PeerEndpoint
    var availability: PieceBitset
    var choked = true
    var interested = false
    var pending: [BlockRequest: Date] = [:]
    var metadataID: UInt8?
    var pexID: UInt8?
    var task: Task<Void, Never>?
    var lastMessage = Date()
    var receiveReservation = 0
    var pumping = false
    var pumpTask: Task<Void, Never>?
    var pexTask: Task<Void, Never>?
    var lastPEX = Date.distantPast
    var advertisedPeers: Set<PeerEndpoint> = []
    var isOutbound = true
}

struct PieceWork {
    var nextBlockBegin = 0
    var received: Set<Int> = []
    var requested: Set<Int> = []
    var verifying = false
}

final class EngineSession {
    var record: EngineRecord
    var snapshot: TransferSnapshot
    var disk: TorrentDisk?
    var wanted: PieceBitset
    var peers: [UUID: ActivePeer] = [:]
    var candidates: [PeerEndpoint] = []
    var knownEndpoints: Set<PeerEndpoint> = []
    var lastAttempt: [PeerEndpoint: Date] = [:]
    var pieceWork: [Int: PieceWork] = [:]
    var connecting: Set<PeerEndpoint> = []
    var connectionTasks: [UUID: Task<Void, Never>] = [:]
    var generation = 0
    var task: Task<Void, Never>?
    var nextAnnounce = Date.distantPast
    var startedAnnounced = false
    var completedAnnounced = false
    var discoveryInProgress = false
    var busy = false
    var progressDirty = false
    var securityScoped = false
    var previousDownloaded: Int64 = 0
    var previousUploaded: Int64 = 0
    var lastRate = Date()
    private lazy var volume = VolumeCapabilities.inspect(destination: record.destination)
    var volumeKey: String { volume.identity }
    var automaticHDD: Bool { volume.isSolidState != true }
    init(record: EngineRecord) {
        self.record = record
        wanted = Self.wantedPieces(record)
        snapshot = TransferSnapshot(id: record.metainfo.id, name: record.metainfo.name, destination: record.destination, isMultiFile: record.metainfo.isMultiFile, state: record.wantedRunning ? .queued : .paused, files: record.metainfo.files.filter { !$0.isPadding }.map { FileSnapshot(file: $0, selected: record.selectedFiles.contains($0.index)) }, selectedBytes: record.metainfo.files.filter { record.selectedFiles.contains($0.index) }.reduce(0) { $0 + $1.length }, downloadedBytes: record.downloaded, uploadedBytes: record.uploaded, seedRatio: record.seedRatio, trackers: record.metainfo.trackerTiers.flatMap { $0 }.map(\.absoluteString))
        if let error = record.quarantineError {
            snapshot.state = .failed
            snapshot.error = error
        }
        previousDownloaded = record.downloaded; previousUploaded = record.uploaded
    }
    static func wantedPieces(_ record: EngineRecord) -> PieceBitset {
        var result = PieceBitset(count: record.metainfo.pieceHashes.count)
        for file in record.metainfo.files where record.selectedFiles.contains(file.index) && file.length > 0 {
            let first = Int(file.offset / Int64(record.metainfo.pieceLength))
            let last = Int((file.offset + file.length - 1) / Int64(record.metainfo.pieceLength))
            for index in first...last { result[index] = true }
        }
        return result
    }
    var selectedComplete: Bool {
        for index in 0..<wanted.count where wanted[index] && !record.verified[index] { return false }
        return true
    }
    var ratioReached: Bool {
        guard let ratio = record.seedRatio else { return false }
        return record.downloaded == 0 || Double(record.uploaded) >= Double(record.downloaded) * ratio
    }
}

/// Owns transfer state and serializes scheduling decisions; payload I/O is delegated
/// to bounded network and disk actors. The UI only receives coalesced snapshots.
public actor TorrentEngine {
    var sessions: [String: EngineSession] = [:]
    var resolving: [String: TransferSnapshot] = [:]
    var libraryError: TransferSnapshot?
    var needsDirtyCheckpoint = false
    var runStatistics = StatisticsSnapshot()
    var statisticsLoaded = false
    var statisticsLoadTask: Task<StatisticsSnapshot, Error>?
    var configuration = EngineSettings()
    var budget = ResourceBudget(limit: 32 * 1024 * 1024)
    let limiter = TransferRateLimiter()
    let persistence: EnginePersistence
    let directory: URL
    var dht: DHTClient?
    var listener: NWListener?
    var listeningPort: UInt16 = 0
    let peerID: Data
    var observers: [UUID: AsyncStream<[TransferSnapshot]>.Continuation] = [:]
    var ticker: Task<Void, Never>?
    var lastCheckpoint = Date()
    var suspended: Set<String> = []
    var shuttingDown = false
    var pendingIncoming = 0
    var preparedArchive: EngineArchive?
    var activationPrepared = false
    var activating = false
    var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    var resolutionTasks: [UUID: Task<TorrentMetainfo, Error>] = [:]

    public init(stateDirectory: URL? = nil) {
        let directory = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Torrenza", isDirectory: true)
        self.directory = directory
        persistence = EnginePersistence(directory: directory)
        peerID = Data(("-TZ0100-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))).utf8)
    }

    nonisolated static func validateMetainfo(_ meta: TorrentMetainfo) throws {
        guard meta.infoHash.count == 20, meta.pieceLength > 0 else { throw TorrentError.invalidMetainfo("Invalid torrent identity or piece length") }
        var length: Int64 = 0
        for (index, file) in meta.files.enumerated() {
            let (next, overflow) = length.addingReportingOverflow(file.length)
            guard !overflow, file.index == index, file.length >= 0, file.offset == length else { throw TorrentError.invalidMetainfo("Invalid torrent file layout") }
            length = next
        }
        let expected = length / Int64(meta.pieceLength) + (length % Int64(meta.pieceLength) == 0 ? 0 : 1)
        guard expected == meta.pieceHashes.count, meta.pieceHashes.allSatisfy({ $0.count == 20 }) else { throw TorrentError.invalidMetainfo("Invalid torrent piece hashes") }
    }

    public func snapshots() -> AsyncStream<[TransferSnapshot]> {
        startTicker()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(currentSnapshots())
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    public func settings() -> EngineSettings { configuration }
    public func statistics() -> StatisticsSnapshot { runStatistics }
    public func sessionHistory() async throws -> [SessionStatistics] {
        try await ensureStatistics()
        var history = try await persistence.sessionHistory().filter { $0.id != runStatistics.current.id }
        history.insert(runStatistics.current, at: 0)
        return history
    }
    func ensureStatistics() async throws {
        guard !statisticsLoaded else { return }
        if statisticsLoadTask == nil {
            let current = runStatistics.current
            statisticsLoadTask = Task { try await self.persistence.startSession(current) }
        }
        do {
            let loaded = try await statisticsLoadTask!.value
            if !statisticsLoaded { runStatistics = loaded; statisticsLoaded = true }
        } catch { statisticsLoadTask = nil; throw error }
    }
    public func loadUIState() async throws -> Data? { try await persistence.loadUIState() }
    public func saveUIState(_ data: Data) async throws {
        guard !shuttingDown else { throw CancellationError() }
        try await persistence.saveUIState(data)
    }
    public func inspect(torrent: Data) throws -> TorrentMetainfo { try MetainfoParser.parse(torrent) }

    /// Providing savedVerifiedPieces explicitly trusts another client's piece status
    /// without hashing. It requires existing payload and a paused import; pieces that
    /// depend on unselected payload are cleared because foreign partfiles are not reused.
    public func add(metainfo: TorrentMetainfo, destination: URL, selectedFiles: Set<Int>, seedRatio: Double? = 1, allowExisting: Bool = false, startPaused: Bool = false, downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0, savedVerifiedPieces: PieceBitset? = nil) async throws -> String {
        guard !shuttingDown else { throw CancellationError() }
        guard libraryError == nil else { throw TorrentError.storage("Saved transfers could not be read; repair or move the saved state before adding transfers") }
        guard downloadedBytes >= 0, uploadedBytes >= 0 else { throw TorrentError.invalidMetainfo("Transfer history cannot contain negative byte counts") }
        try Self.validateMetainfo(metainfo)
        if let savedVerifiedPieces {
            guard allowExisting, startPaused, savedVerifiedPieces.count == metainfo.pieceHashes.count else {
                throw TorrentError.invalidMetainfo("Saved piece status requires a paused import of existing files and a matching piece count")
            }
        }
        guard sessions[metainfo.id] == nil else { throw TorrentError.storage("This torrent is already in your library") }
        let valid = Set(metainfo.files.filter { !$0.isPadding }.map(\.index))
        guard !selectedFiles.isEmpty, selectedFiles.isSubset(of: valid) else { throw TorrentError.storage("Choose at least one valid file") }
        guard seedRatio == nil || (seedRatio!.isFinite && seedRatio! >= 0) else { throw TorrentError.invalidMetainfo("Invalid seed ratio") }
        let destination = destination.standardizedFileURL
        let requestedPaths = Set(metainfo.files.filter { selectedFiles.contains($0.index) }.map { $0.path.reduce(destination) { $0.appendingPathComponent($1) }.standardizedFileURL.path })
        for existing in sessions.values {
            let ownedPaths = Set((existing.record.ownedSignatures ?? []).map { existing.record.destination.appendingPathComponent($0.path).standardizedFileURL.path })
            guard requestedPaths.isDisjoint(with: ownedPaths) else { throw TorrentError.storage("Another managed torrent already owns one of these destination files") }
        }
        let scoped = destination.startAccessingSecurityScopedResource()
        let bookmark = try? destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var record = EngineRecord(metainfo: metainfo, destination: destination, bookmark: bookmark, selectedFiles: selectedFiles, seedRatio: seedRatio, downloaded: downloadedBytes, uploaded: uploadedBytes, wantedRunning: !startPaused, verified: PieceBitset(count: metainfo.pieceHashes.count))
        record.volumeUUID = try? destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let session = EngineSession(record: record)
        session.securityScoped = scoped
        do {
            if savedVerifiedPieces != nil {
                try await Task.detached(priority: .utility) {
                    try QBittorrentImport.preflight(metainfo: metainfo, destination: destination, selectedFiles: selectedFiles)
                }.value
            }
            try await ensureStatistics()
            let disk = try TorrentDisk(metainfo: metainfo, destination: destination, selectedFiles: selectedFiles, allowExisting: allowExisting, requireExistingPayload: savedVerifiedPieces != nil)
            try await disk.prepare()
            session.disk = disk
            try await updateOwnership(session)
            sessions[metainfo.id] = session
            if var savedVerifiedPieces {
                // Only selected payload is imported. Pieces touching skipped files may
                // depend on qBittorrent's partfile, which is not available to our disk.
                for index in 0..<savedVerifiedPieces.count where !session.wanted[index] {
                    savedVerifiedPieces[index] = false
                }
                for file in metainfo.files where !file.isPadding && !selectedFiles.contains(file.index) && file.length > 0 {
                    let first = Int(file.offset / Int64(metainfo.pieceLength))
                    let last = Int((file.offset + file.length - 1) / Int64(metainfo.pieceLength))
                    for index in first...last { savedVerifiedPieces[index] = false }
                }
                session.record.verified = savedVerifiedPieces
                await refreshProgress(session)
            } else if allowExisting {
                await verifyAll(metainfo.id)
                if session.snapshot.state == .checking { session.snapshot.state = session.record.wantedRunning ? .queued : .paused }
            }
            try await checkpoint()
            startTicker()
            await schedule()
            return metainfo.id
        } catch {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            sessions.removeValue(forKey: metainfo.id)
            throw error
        }
    }

    public func start(_ id: String) async {
        guard !shuttingDown else { return }
        guard let session = sessions[id] else { return }
        session.record.wantedRunning = true
        session.record.quarantineError = nil
        session.snapshot.error = nil
        if ![.downloading, .seeding, .checking].contains(session.snapshot.state) { session.snapshot.state = .queued }
        startTicker()
        await schedule()
        try? await checkpoint()
    }

    public func pause(_ id: String) async {
        guard !shuttingDown else { return }
        guard let session = sessions[id] else { return }
        session.record.wantedRunning = false
        await stopSession(id, state: session.record.quarantineError == nil ? .paused : .failed)
        try? await checkpoint()
        await schedule()
    }

    public func remove(_ id: String, deleteFiles: Bool = false) async throws {
        guard !shuttingDown else { throw CancellationError() }
        guard let session = sessions[id] else { return }
        session.record.wantedRunning = false
        await stopSession(id, state: .paused)
        if deleteFiles {
            do {
                try await openDisk(session)
                try await updateOwnership(session)
                try await TorrentDisk.removeOwnedFiles(destination: session.record.destination, signatures: session.record.ownedSignatures ?? [])
                await session.disk?.close()
            } catch {
                await quarantine(id, error: error)
                throw error
            }
        }
        if session.securityScoped { session.record.destination.stopAccessingSecurityScopedResource() }
        sessions.removeValue(forKey: id)
        try await checkpoint()
        await schedule()
    }

    public func recheck(_ id: String) async {
        guard !shuttingDown else { return }
        guard let session = sessions[id] else { return }
        session.record.quarantineError = nil
        session.snapshot.error = nil
        await stopSession(id, state: .checking)
        await verifyAll(id)
        if session.record.quarantineError == nil && ![.failed, .unavailable].contains(session.snapshot.state) { session.snapshot.state = session.record.wantedRunning ? .queued : .paused }
        try? await checkpoint()
        await schedule()
    }

    public func setSeedRatio(_ id: String, ratio: Double?) async {
        guard !shuttingDown else { return }
        guard let session = sessions[id], ratio == nil || (ratio!.isFinite && ratio! >= 0) else { return }
        session.record.seedRatio = ratio; session.snapshot.seedRatio = ratio
        await schedule()
        try? await checkpoint()
    }

    public func setSelectedFiles(_ id: String, selectedFiles: Set<Int>) async throws {
        guard !shuttingDown else { throw CancellationError() }
        guard let session = sessions[id] else { return }
        let valid = Set(session.record.metainfo.files.filter { !$0.isPadding }.map(\.index))
        guard !selectedFiles.isEmpty, selectedFiles.isSubset(of: valid) else { throw TorrentError.storage("Choose at least one valid file") }
        for file in session.record.metainfo.files where selectedFiles.contains(file.index) && !session.record.selectedFiles.contains(file.index) {
            let path = file.path.reduce(session.record.destination) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: path.path) {
                guard let owned = session.record.ownedSignatures?.first(where: { $0.path == file.path.joined(separator: "/") }) else { throw TorrentError.storage("A newly selected file already exists and is not owned by this torrent") }
                try await TorrentDisk.validateOwnedFiles(destination: session.record.destination, signatures: [owned])
            }
        }
        do {
            await stopSession(id, state: .paused)
            // The current selection must still exist before adding new files;
            // only newly selected payloads may be created below.
            try await openDisk(session)
            try await updateOwnership(session)
            await session.disk?.close()
            session.record.selectedFiles = selectedFiles
            session.wanted = EngineSession.wantedPieces(session.record)
            session.disk = nil
            try await openDisk(session, allowNewFiles: true)
            try await updateOwnership(session)
            await verifyAll(id)
            if let error = session.record.quarantineError {
                session.snapshot.state = .failed
                session.snapshot.error = error
            } else if ![.failed, .unavailable].contains(session.snapshot.state) {
                session.snapshot.state = session.record.wantedRunning ? .queued : .paused
            }
            try await checkpoint()
            await schedule()
        } catch {
            await quarantine(id, error: error)
            throw error
        }
    }

    public func updateSettings(_ settings: EngineSettings) async {
        guard !shuttingDown else { return }
        var settings = settings
        settings.maxDownloads = min(16, max(1, settings.maxDownloads))
        settings.maxSeeds = min(16, max(0, settings.maxSeeds))
        settings.maxPeers = min(200, max(1, settings.maxPeers))
        settings.payloadBudget = configuration.payloadBudget // fixed live budget; prevents unbalanced reservations
        settings.downloadLimit = max(0, settings.downloadLimit)
        settings.uploadLimit = max(0, settings.uploadLimit)
        configuration = settings
        await limiter.configure(download: settings.downloadLimit, upload: settings.uploadLimit)
        try? await checkpoint()
        await schedule()
    }

    /// Validates a candidate profile before the current profile is stopped.
    /// No payload files are opened and no networking or new session is started.
    public func prepareForActivation() async throws {
        guard sessions.isEmpty, !statisticsLoaded else {
            throw TorrentError.storage("This profile engine has already been activated")
        }
        let archive = try await persistence.load()
        if let archive {
            var identities = Set<String>()
            for record in archive.records {
                try Self.validateMetainfo(record.metainfo)
                let validFiles = Set(record.metainfo.files.filter { !$0.isPadding }.map(\.index))
                guard identities.insert(record.metainfo.id).inserted,
                      record.verified.count == record.metainfo.pieceHashes.count,
                      !record.selectedFiles.isEmpty, record.selectedFiles.isSubset(of: validFiles),
                      record.downloaded >= 0, record.uploaded >= 0,
                      record.seedRatio == nil || (record.seedRatio!.isFinite && record.seedRatio! >= 0) else {
                    throw TorrentError.storage("Saved transfer state is invalid")
                }
            }
        }
        try await persistence.validateStatistics()
        preparedArchive = archive
        activationPrepared = true
    }

    public func activatePreparedProfile() async throws {
        if !activationPrepared { try await prepareForActivation() }
        guard !shuttingDown, sessions.isEmpty, !statisticsLoaded else {
            throw TorrentError.storage("This profile engine cannot be activated again")
        }
        activating = true
        defer { activating = false }
        do {
            try await restorePreparedArchive()
            try await checkpoint()
            needsDirtyCheckpoint = false
            activationPrepared = false
            preparedArchive = nil
            activating = false
            startTicker()
            // Publish the restored library before opening any active payloads.
            // A slow or disconnected destination must not hold the startup UI.
            startBackgroundTask { engine in await engine.schedule() }
        } catch {
            // Prevent a failed activation from replacing the saved archive.
            libraryError = TransferSnapshot(id: "library-error", name: "Saved transfers", state: .failed, error: "Saved state was preserved: \(error.localizedDescription)")
            await quiesce()
            await closeProfileResources()
            throw error
        }
    }

    public func restore() async {
        guard sessions.isEmpty else { return }
        do { try await prepareForActivation(); try await activatePreparedProfile() }
        catch {
            libraryError = TransferSnapshot(id: "library-error", name: "Saved transfers", state: .failed, error: "Saved state was preserved: \(error.localizedDescription)")
            publishSnapshots()
        }
    }

    private func restorePreparedArchive() async throws {
        try await ensureStatistics()
        guard let archive = preparedArchive else { return }
        needsDirtyCheckpoint = archive.cleanShutdown == true
        configuration = archive.settings
        await limiter.configure(download: configuration.downloadLimit, upload: configuration.uploadLimit)
        configuration.payloadBudget = 32 * 1024 * 1024
        for var record in archive.records {
            var scoped = false
            if let bookmark = record.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    record.destination = resolved; scoped = resolved.startAccessingSecurityScopedResource()
                    if stale { record.bookmark = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
                }
            }
            let session = EngineSession(record: record); session.securityScoped = scoped
            sessions[record.metainfo.id] = session
            // Startup trusts the saved piece map, including after an interrupted
            // session. Payload access is deferred until the torrent actually runs;
            // explicit Recheck remains available when verification is desired.
            await refreshProgress(session)
        }
    }

    public func suspend() async {
        guard !shuttingDown else { return }
        suspended = Set(sessions.filter { $0.value.record.wantedRunning }.map(\.key))
        for id in Array(suspended) { await stopSession(id, state: .paused) }
        try? await checkpoint()
        updateActivity()
    }
    public func resume() async {
        guard !shuttingDown else { return }
        for id in suspended { if let session = sessions[id], session.record.quarantineError == nil { session.snapshot.state = .queued } }
        suspended.removeAll()
        await schedule()
    }
    /// Stops all work before returning. A failed save leaves this engine stopped
    /// with its in-memory state available for retry or recovery.
    public func shutdownForProfileSwitch() async throws {
        await quiesce()
        guard statisticsLoaded || !sessions.isEmpty else {
            await closeProfileResources()
            try await persistence.close()
            return
        }
        let previousEnd = runStatistics.current.endedAt
        runStatistics.current.endedAt = Date()
        do {
            try await checkpoint(cleanShutdown: true)
            await closeProfileResources()
            try await persistence.close()
        } catch {
            runStatistics.current.endedAt = previousEnd
            throw error
        }
    }

    /// Call only after a failed shutdown checkpoint. After a successful shutdown,
    /// create a fresh engine for the old directory to begin a new session.
    public func resumeAfterFailedProfileSwitch() async {
        dht = nil
        shuttingDown = false
        for session in sessions.values where session.record.wantedRunning && session.record.quarantineError == nil {
            session.snapshot.state = .queued
        }
        needsDirtyCheckpoint = true
        await schedule()
    }

    public func shutdown() async {
        do { try await shutdownForProfileSwitch() }
        catch { await closeProfileResources(); try? await persistence.close() }
    }

    @discardableResult
    func startBackgroundTask(_ operation: @escaping @Sendable (isolated TorrentEngine) async -> Void) -> Task<Void, Never> {
        guard !shuttingDown else { return Task {} }
        let id = UUID()
        let task = Task {
            await operation(self)
            self.backgroundTasks.removeValue(forKey: id)
        }
        backgroundTasks[id] = task
        return task
    }

    private func quiesce() async {
        shuttingDown = true
        let oldTicker = ticker
        ticker?.cancel(); ticker = nil
        listener?.cancel(); listener = nil; listeningPort = 0
        let resolutions = Array(resolutionTasks.values)
        for task in resolutions { task.cancel() }
        for task in backgroundTasks.values { task.cancel() }
        for id in Array(sessions.keys) { await stopSession(id, state: .paused) }
        await dht?.stop()
        for task in resolutions { _ = try? await task.value }
        // Includes peer handlers already removed from a session while an I/O
        // operation was in flight, incoming handshakes, and tracker announces.
        while !backgroundTasks.isEmpty {
            let tasks = Array(backgroundTasks.values)
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
        }
        await oldTicker?.value
        publishSnapshots()
    }

    private func closeProfileResources() async {
        dht = nil
        for session in sessions.values {
            await session.disk?.close(); session.disk = nil
            if session.securityScoped { session.record.destination.stopAccessingSecurityScopedResource(); session.securityScoped = false }
        }
    }
}
