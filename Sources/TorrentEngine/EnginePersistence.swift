import Foundation
import TorrentCore
import TorrentStorage
import TorrentWire

struct EngineRecord: Codable, Sendable {
    var metainfo: TorrentMetainfo
    var destination: URL
    var bookmark: Data?
    var volumeUUID: String? = nil
    var diskSignatures: [DiskSignature]? = nil
    var ownedSignatures: [DiskSignature]? = nil
    var selectedFiles: Set<Int>
    var seedRatio: Double?
    var downloaded: Int64
    var uploaded: Int64
    var fileUploadedBytes: [Int: Int64]? = nil
    var fileUploadHistoryComplete: Bool? = nil
    var wantedRunning: Bool
    var quarantineError: String? = nil
    var verified: PieceBitset
}

extension EngineRecord {
    mutating func initializeFileUploadHistory() {
        guard fileUploadedBytes == nil else { return }
        fileUploadedBytes = [:]
        fileUploadHistoryComplete = uploaded == 0
        // Only an unpadded single-file torrent has an unambiguous historical split.
        if metainfo.files.count == 1, let file = metainfo.files.first, !file.isPadding {
            fileUploadedBytes = [file.index: uploaded]
            fileUploadHistoryComplete = true
        }
    }

    var hasValidFileUploadHistory: Bool {
        guard let counters = fileUploadedBytes else { return fileUploadHistoryComplete == nil }
        guard fileUploadHistoryComplete != nil else { return false }
        let validFiles = Set(metainfo.files.filter { !$0.isPadding }.map(\.index))
        var total: Int64 = 0
        for (index, count) in counters {
            guard validFiles.contains(index), count >= 0 else { return false }
            let result = total.addingReportingOverflow(count)
            guard !result.overflow else { return false }
            total = result.partialValue
        }
        return total <= uploaded
    }
}

struct EngineArchive: Codable, Sendable {
    var version = 1
    var cleanShutdown: Bool? = nil
    var settings: EngineSettings
    var records: [EngineRecord]
}

private struct LifetimeTotals: Codable, Sendable {
    var downloaded: Int64
    var uploaded: Int64
}

private struct EngineDatabaseHeader: Codable, Sendable {
    var version: Int
    var cleanShutdown: Bool?
    var settings: EngineSettings
}

private struct MutableTransferRecord: Codable, Sendable {
    var destination: URL
    var bookmark: Data?
    var volumeUUID: String?
    var diskSignatures: [DiskSignature]?
    var ownedSignatures: [DiskSignature]?
    var selectedFiles: Set<Int>
    var seedRatio: Double?
    var downloaded: Int64
    var uploaded: Int64
    var fileUploadedBytes: [Int: Int64]? = nil
    var fileUploadHistoryComplete: Bool? = nil
    var wantedRunning: Bool
    var quarantineError: String? = nil
    var verified: PieceBitset
    init(_ record: EngineRecord) {
        destination = record.destination; bookmark = record.bookmark; volumeUUID = record.volumeUUID
        diskSignatures = nil; ownedSignatures = nil; selectedFiles = record.selectedFiles; seedRatio = record.seedRatio
        downloaded = record.downloaded; uploaded = record.uploaded
        fileUploadedBytes = record.fileUploadedBytes; fileUploadHistoryComplete = record.fileUploadHistoryComplete
        wantedRunning = record.wantedRunning; quarantineError = record.quarantineError; verified = record.verified
    }
    func record(metainfo: TorrentMetainfo) -> EngineRecord {
        EngineRecord(metainfo: metainfo, destination: destination, bookmark: bookmark, volumeUUID: volumeUUID, diskSignatures: diskSignatures, ownedSignatures: ownedSignatures, selectedFiles: selectedFiles, seedRatio: seedRatio, downloaded: downloaded, uploaded: uploaded, fileUploadedBytes: fileUploadedBytes, fileUploadHistoryComplete: fileUploadHistoryComplete, wantedRunning: wantedRunning, quarantineError: quarantineError, verified: verified)
    }
}

/// One database owns engine, discovery and presentation state. Immutable metadata
/// is inserted once, while changed checkpoints are committed in one transaction.
actor EnginePersistence {
    private let store: SQLiteStore
    private let directory: URL
    private var savedMetadata: Set<String> = []
    private var savedTransfers: [String: Data] = [:]
    private var savedSignatures: [String: Data] = [:]
    private var savedOwnership: [String: [DiskSignature]] = [:]
    private var savedHeader: Data?
    private var savedContacts: Data?
    private var savedSession: Data?
    private var savedLifetime: Data?
    init(directory: URL) {
        self.directory = directory
        self.store = SQLiteStore(url: directory.appendingPathComponent("Torrenza.sqlite"))
    }
    func load() async throws -> EngineArchive? {
        if let current = try await loadDatabase() { return current }
        let legacy = DurableJSONStore<EngineArchive>(directory: directory)
        guard let archive = try await legacy.load() else {
            try await migrateStandaloneDHT()
            return nil
        }
        guard archive.version == 1 else { throw TorrentError.storage("Unsupported transfer state version") }
        let contacts = try await legacyDHTData()
        try await save(archive, contacts: contacts)
        guard let confirmed = try await loadDatabase(), confirmed.records.count == archive.records.count else {
            throw TorrentError.storage("Legacy transfer migration could not be verified")
        }
        try await removeLegacyFile("transfers.json")
        if contacts != nil { try await removeLegacyFile("dht.json") }
        return confirmed
    }
    private func loadDatabase() async throws -> EngineArchive? {
        guard let bytes = try await store.read(namespace: "engine", key: "settings") else {
            let transfers = try await store.keys(namespace: "transfers")
            let metadata = try await store.keys(namespace: "metainfo")
            guard transfers.isEmpty, metadata.isEmpty else { throw TorrentError.storage("Saved library settings are missing") }
            return nil
        }
        let header = try JSONDecoder().decode(EngineDatabaseHeader.self, from: bytes)
        guard header.version == 1 else { throw TorrentError.storage("Unsupported transfer state version") }
        let metadata = try await store.keys(namespace: "metainfo")
        let transfers = try await store.readAll(namespace: "transfers")
        let signatures = try await store.readAll(namespace: "signatures")
        savedOwnership = [:]
        var records: [EngineRecord] = []
        for (id, bytes) in transfers {
            // Decode one torrent at a time instead of holding the whole library's
            // serialized metadata alongside its decoded representation at startup.
            guard let rawMeta = try await store.read(namespace: "metainfo", key: id) else { throw TorrentError.storage("Saved torrent metadata is missing") }
            let meta = try JSONDecoder().decode(TorrentMetainfo.self, from: rawMeta)
            guard meta.id == id else { throw TorrentError.storage("Saved torrent identity does not match") }
            let mutable = try JSONDecoder().decode(MutableTransferRecord.self, from: bytes)
            var record = mutable.record(metainfo: meta)
            if let signatureData = signatures[id] { record.diskSignatures = try JSONDecoder().decode([DiskSignature].self, from: signatureData) }
            if let data = try await store.read(namespace: "ownership", key: id) {
                record.ownedSignatures = try JSONDecoder().decode([DiskSignature].self, from: data)
                savedOwnership[id] = record.ownedSignatures
            }
            records.append(record)
        }
        savedMetadata = Set(metadata); savedTransfers = transfers; savedSignatures = signatures; savedHeader = bytes
        return EngineArchive(version: header.version, cleanShutdown: header.cleanShutdown, settings: header.settings, records: records)
    }
    func save(_ archive: EngineArchive, contacts: Data? = nil, statistics: StatisticsSnapshot? = nil) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var entries: [SQLiteEntry] = []
        let header = EngineDatabaseHeader(version: archive.version, cleanShutdown: archive.cleanShutdown, settings: archive.settings)
        let headerData = try encoder.encode(header)
        if savedHeader != headerData { entries.append(SQLiteEntry(namespace: "engine", key: "settings", value: headerData)) }
        var transfers: [String: Data] = [:]
        var signatures: [String: Data] = [:]
        var ownership: [String: [DiskSignature]] = [:]
        let current = Set(archive.records.map { $0.metainfo.id })
        for record in archive.records {
            let id = record.metainfo.id
            if !savedMetadata.contains(id) { entries.append(SQLiteEntry(namespace: "metainfo", key: id, value: try encoder.encode(record.metainfo))) }
            if let diskSignatures = record.diskSignatures {
                let data = archive.cleanShutdown == true || savedSignatures[id] == nil ? try encoder.encode(diskSignatures) : savedSignatures[id]!
                signatures[id] = data
                if savedSignatures[id] != data { entries.append(SQLiteEntry(namespace: "signatures", key: id, value: data)) }
            }
            if let owned = record.ownedSignatures {
                ownership[id] = owned
                if savedOwnership[id] != owned { entries.append(SQLiteEntry(namespace: "ownership", key: id, value: try encoder.encode(owned))) }
            }
            let value = try encoder.encode(MutableTransferRecord(record))
            transfers[id] = value
            if savedTransfers[id] != value { entries.append(SQLiteEntry(namespace: "transfers", key: id, value: value)) }
        }
        for removed in savedMetadata.subtracting(current) {
            entries.append(SQLiteEntry(namespace: "metainfo", key: removed, value: nil))
            entries.append(SQLiteEntry(namespace: "transfers", key: removed, value: nil))
            entries.append(SQLiteEntry(namespace: "signatures", key: removed, value: nil))
            entries.append(SQLiteEntry(namespace: "ownership", key: removed, value: nil))
        }
        if let contacts, contacts != savedContacts { entries.append(SQLiteEntry(namespace: "dht", key: "contacts", value: contacts)) }
        var sessionData: Data?, lifetimeData: Data?
        if let statistics {
            sessionData = try encoder.encode(statistics.current)
            lifetimeData = try encoder.encode(LifetimeTotals(downloaded: statistics.lifetimeDownloadedBytes, uploaded: statistics.lifetimeUploadedBytes))
            if sessionData != savedSession { entries.append(SQLiteEntry(namespace: "sessions", key: statistics.current.id, value: sessionData)) }
            if lifetimeData != savedLifetime { entries.append(SQLiteEntry(namespace: "statistics", key: "lifetime", value: lifetimeData)) }
        }
        if !entries.isEmpty { try await store.write(entries) }
        savedMetadata = current; savedTransfers = transfers; savedSignatures = signatures; savedOwnership = ownership; savedHeader = headerData
        if let contacts { savedContacts = contacts }
        if let sessionData { savedSession = sessionData }
        if let lifetimeData { savedLifetime = lifetimeData }
    }
    /// Persist a stopped error even when quarantining cancelled the failing peer task.
    /// This does not flush unrelated torrents or rewrite their progress.
    func saveQuarantine(_ record: EngineRecord) async throws {
        let id = record.metainfo.id
        guard savedMetadata.contains(id) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = try encoder.encode(MutableTransferRecord(record))
        try await store.write([SQLiteEntry(namespace: "transfers", key: id, value: value)])
        savedTransfers[id] = value
    }

    func validateStatistics() async throws {
        for data in try await store.readAll(namespace: "sessions").values {
            let session = try JSONDecoder().decode(SessionStatistics.self, from: data)
            guard session.downloadedBytes >= 0, session.uploadedBytes >= 0 else {
                throw TorrentError.storage("Saved session statistics are invalid")
            }
        }
        if let data = try await store.read(namespace: "statistics", key: "lifetime") {
            let totals = try JSONDecoder().decode(LifetimeTotals.self, from: data)
            guard totals.downloaded >= 0, totals.uploaded >= 0 else {
                throw TorrentError.storage("Saved lifetime statistics are invalid")
            }
        }
    }
    func close() async throws { try await store.close() }

    func startSession(_ current: SessionStatistics) async throws -> StatisticsSnapshot {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var entries: [SQLiteEntry] = []
        let history = try await store.readAll(namespace: "sessions")
        for (id, data) in history {
            var previous = try decoder.decode(SessionStatistics.self, from: data)
            if previous.endedAt == nil && !previous.interrupted && id != current.id {
                previous.interrupted = true
                entries.append(SQLiteEntry(namespace: "sessions", key: id, value: try encoder.encode(previous)))
            }
        }
        var totals = LifetimeTotals(downloaded: 0, uploaded: 0)
        if let data = try await store.read(namespace: "statistics", key: "lifetime") {
            totals = try decoder.decode(LifetimeTotals.self, from: data)
        } else {
            // First schema upgrade retains all known historical payload counters.
            for data in try await store.readAll(namespace: "transfers").values {
                let record = try decoder.decode(MutableTransferRecord.self, from: data)
                totals.downloaded += record.downloaded; totals.uploaded += record.uploaded
            }
        }
        entries.append(SQLiteEntry(namespace: "sessions", key: current.id, value: try encoder.encode(current)))
        entries.append(SQLiteEntry(namespace: "statistics", key: "lifetime", value: try encoder.encode(totals)))
        try await store.write(entries)
        return StatisticsSnapshot(current: current, lifetimeDownloadedBytes: totals.downloaded, lifetimeUploadedBytes: totals.uploaded)
    }
    func sessionHistory() async throws -> [SessionStatistics] {
        try await store.readAll(namespace: "sessions").values.map { try JSONDecoder().decode(SessionStatistics.self, from: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    func loadUIState() async throws -> Data? { try await store.read(namespace: "ui", key: "state") }
    func saveUIState(_ data: Data) async throws { try await store.write([SQLiteEntry(namespace: "ui", key: "state", value: data)]) }
    func loadDHTContacts() async throws -> Data? { try await store.read(namespace: "dht", key: "contacts") }

    private func legacyDHTData() async throws -> Data? {
        let url = directory.appendingPathComponent("dht.json")
        let candidate: Data? = try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { return nil }
            let data = try Data(contentsOf: url)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
            return data
        }.value
        guard let candidate else { return nil }
        let validator = DHTClient(bootstrapNodes: [])
        do { try await validator.importContacts(candidate); return candidate }
        catch { return nil } // preserve corrupt legacy contacts for inspection
    }
    private func migrateStandaloneDHT() async throws {
        guard let contacts = try await legacyDHTData() else { return }
        try await store.write([SQLiteEntry(namespace: "dht", key: "contacts", value: contacts)])
        guard try await store.read(namespace: "dht", key: "contacts") == contacts else { throw TorrentError.storage("DHT migration could not be verified") }
        try await removeLegacyFile("dht.json")
    }
    private func removeLegacyFile(_ name: String) async throws {
        let url = directory.appendingPathComponent(name)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }.value
    }
}

actor TransferRateLimiter {
    private struct Bucket {
        var limit: Int64 = 0
        var tokens: Double = 16_384
        var updated = ContinuousClock.now
    }
    private var download = Bucket(), upload = Bucket()
    func configure(download: Int64, upload: Int64) {
        if self.download.limit != download { self.download = Bucket(limit: download) }
        if self.upload.limit != upload { self.upload = Bucket(limit: upload) }
    }
    /// A small token bucket permits one block of burst without reserving hours of
    /// future slots. Cancelled requests leave no debt, and changed limits take
    /// effect while requests are waiting.
    func wait(bytes: Int, upload isUpload: Bool) async throws {
        while true {
            try Task.checkCancellation()
            var bucket = isUpload ? upload : download
            guard bucket.limit > 0 else { return }
            let now = ContinuousClock.now
            let components = bucket.updated.duration(to: now).components
            let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            bucket.tokens = min(Double(max(16_384, bytes)), bucket.tokens + max(0, elapsed) * Double(bucket.limit))
            bucket.updated = now
            if bucket.tokens >= Double(bytes) {
                bucket.tokens -= Double(bytes)
                if isUpload { upload = bucket } else { download = bucket }
                return
            }
            if isUpload { upload = bucket } else { download = bucket }
            let wait = min(0.5, max(0.001, (Double(bytes) - bucket.tokens) / Double(bucket.limit)))
            try await Task.sleep(for: .seconds(wait))
        }
    }
}
