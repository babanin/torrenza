import Foundation

public struct TorrentFile: Sendable, Codable, Equatable, Identifiable {
    public let index: Int
    public let path: [String]
    public let length: Int64
    public let offset: Int64
    public let isPadding: Bool
    public var id: Int { index }
    public init(index: Int, path: [String], length: Int64, offset: Int64, isPadding: Bool = false) {
        self.index = index; self.path = path; self.length = length; self.offset = offset; self.isPadding = isPadding
    }
}

public struct TorrentMetainfo: Sendable, Codable, Equatable {
    public let infoHash: Data
    public let rawInfo: Data
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: PieceHashes
    public let files: [TorrentFile]
    public let trackerTiers: [[URL]]
    public let isPrivate: Bool
    public let isMultiFile: Bool
    public var totalLength: Int64 { files.reduce(0) { $0 + $1.length } }
    public var id: String { infoHash.hexString }
    public init(infoHash: Data, rawInfo: Data, name: String, pieceLength: Int, pieceHashes: [Data], files: [TorrentFile], trackerTiers: [[URL]], isPrivate: Bool, isMultiFile: Bool) {
        self.init(infoHash: infoHash, rawInfo: rawInfo, name: name, pieceLength: pieceLength, pieceHashes: PieceHashes(pieceHashes), files: files, trackerTiers: trackerTiers, isPrivate: isPrivate, isMultiFile: isMultiFile)
    }
    public init(infoHash: Data, rawInfo: Data, name: String, pieceLength: Int, pieceHashes: PieceHashes, files: [TorrentFile], trackerTiers: [[URL]], isPrivate: Bool, isMultiFile: Bool) {
        self.infoHash = infoHash; self.rawInfo = rawInfo; self.name = name; self.pieceLength = pieceLength; self.pieceHashes = pieceHashes; self.files = files; self.trackerTiers = trackerTiers; self.isPrivate = isPrivate; self.isMultiFile = isMultiFile
    }
    public func lengthOfPiece(_ index: Int) -> Int { Int(min(Int64(pieceLength), totalLength - Int64(index) * Int64(pieceLength))) }
}

public struct PeerEndpoint: Sendable, Codable, Hashable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public struct MagnetLink: Sendable, Equatable {
    public let infoHash: Data
    public let displayName: String?
    public let trackers: [URL]
    public let peers: [PeerEndpoint]
    public init(infoHash: Data, displayName: String?, trackers: [URL], peers: [PeerEndpoint] = []) {
        self.infoHash = infoHash; self.displayName = displayName; self.trackers = trackers; self.peers = peers
    }
}

public enum TorrentError: Error, Sendable, LocalizedError, Equatable {
    case invalidMetainfo(String), unsupported(String), invalidMessage(String), storage(String), network(String), cancelled
    public var errorDescription: String? {
        switch self { case .invalidMetainfo(let s), .unsupported(let s), .invalidMessage(let s), .storage(let s), .network(let s): s; case .cancelled: "Cancelled" }
    }
}

public enum StorageProfile: String, Codable, Sendable, CaseIterable { case automatic, ssd, hdd }
public struct EngineSettings: Codable, Sendable, Equatable {
    public var maxDownloads = 2
    public var maxSeeds = 2
    public var maxPeers = 60
    public var payloadBudget = 32 * 1024 * 1024
    public var downloadLimit: Int64 = 0
    public var uploadLimit: Int64 = 0
    public var defaultSeedRatio: Double = 1
    public var preventIdleSleep = false
    public var storageProfile: StorageProfile = .automatic
    /// Explicit destination overrides; missing entries inherit the default profile.
    public var destinationProfiles: [String: StorageProfile] = [:]
    public var bootstrapNodes = [PeerEndpoint(host: "dht.transmissionbt.com", port: 6881), PeerEndpoint(host: "dht.libtorrent.org", port: 25401)]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case maxDownloads, maxSeeds, maxPeers, payloadBudget, downloadLimit, uploadLimit, defaultSeedRatio, preventIdleSleep, storageProfile, destinationProfiles, bootstrapNodes
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxDownloads = min(16, max(1, try values.decodeIfPresent(Int.self, forKey: .maxDownloads) ?? maxDownloads))
        maxSeeds = min(16, max(0, try values.decodeIfPresent(Int.self, forKey: .maxSeeds) ?? maxSeeds))
        maxPeers = min(200, max(1, try values.decodeIfPresent(Int.self, forKey: .maxPeers) ?? maxPeers))
        payloadBudget = 32 * 1024 * 1024
        downloadLimit = max(0, try values.decodeIfPresent(Int64.self, forKey: .downloadLimit) ?? 0)
        uploadLimit = max(0, try values.decodeIfPresent(Int64.self, forKey: .uploadLimit) ?? 0)
        let ratio = try values.decodeIfPresent(Double.self, forKey: .defaultSeedRatio) ?? 1
        defaultSeedRatio = ratio.isFinite && ratio >= 0 ? ratio : 1
        preventIdleSleep = try values.decodeIfPresent(Bool.self, forKey: .preventIdleSleep) ?? false
        storageProfile = try values.decodeIfPresent(StorageProfile.self, forKey: .storageProfile) ?? .automatic
        destinationProfiles = try values.decodeIfPresent([String: StorageProfile].self, forKey: .destinationProfiles) ?? [:]
        bootstrapNodes = Array((try values.decodeIfPresent([PeerEndpoint].self, forKey: .bootstrapNodes) ?? bootstrapNodes).prefix(16))
    }
}

public enum TransferState: String, Sendable, Codable { case resolving, queued, checking, downloading, seeding, paused, completed, unavailable, failed }
public struct SessionStatistics: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var interrupted: Bool
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    public init(id: String = UUID().uuidString, startedAt: Date = Date(), endedAt: Date? = nil, interrupted: Bool = false, downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.interrupted = interrupted; self.downloadedBytes = downloadedBytes; self.uploadedBytes = uploadedBytes
    }
}
public struct StatisticsSnapshot: Sendable, Codable, Equatable {
    public var current: SessionStatistics
    public var lifetimeDownloadedBytes: Int64
    public var lifetimeUploadedBytes: Int64
    public init(current: SessionStatistics = .init(), lifetimeDownloadedBytes: Int64 = 0, lifetimeUploadedBytes: Int64 = 0) {
        self.current = current; self.lifetimeDownloadedBytes = lifetimeDownloadedBytes; self.lifetimeUploadedBytes = lifetimeUploadedBytes
    }
}
public struct SwarmCounts: Sendable, Codable, Equatable {
    public var connectedSeeds: Int = 0
    public var connectedPeers: Int = 0
    public var reportedSeeds: Int?
    public var reportedPeers: Int?
    public var tracker: String?
    public var reportedAt: Date?
    public var announceInterval: TimeInterval = 1800
    public init() {}
    public func isStale(at date: Date, state: TransferState) -> Bool {
        guard let reportedAt else { return true }
        return ![.downloading, .seeding].contains(state) || date.timeIntervalSince(reportedAt) > 2 * max(announceInterval, 60)
    }
}
public struct FileSnapshot: Sendable, Equatable, Identifiable {
    public let file: TorrentFile
    public var selected: Bool
    public var verifiedBytes: Int64
    public var uploadedBytes: Int64
    public var id: Int { file.index }
    public init(file: TorrentFile, selected: Bool, verifiedBytes: Int64 = 0, uploadedBytes: Int64 = 0) { self.file = file; self.selected = selected; self.verifiedBytes = verifiedBytes; self.uploadedBytes = uploadedBytes }
}
public struct TransferSnapshot: Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var destination: URL?
    public var isMultiFile: Bool
    public var state: TransferState
    public var files: [FileSnapshot]
    /// False when aggregate uploads include history that cannot be attributed to individual files.
    public var fileUploadHistoryComplete: Bool
    public var completedBytes: Int64
    public var selectedBytes: Int64
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    public var downloadRate: Double
    public var uploadRate: Double
    public var seedRatio: Double?
    public var swarm: SwarmCounts
    public var error: String?
    public var trackers: [String]
    public var progress: Double { selectedBytes > 0 ? min(1, Double(completedBytes) / Double(selectedBytes)) : 0 }
    public init(id: String, name: String, destination: URL? = nil, isMultiFile: Bool = false, state: TransferState = .queued, files: [FileSnapshot] = [], fileUploadHistoryComplete: Bool = true, completedBytes: Int64 = 0, selectedBytes: Int64 = 0, downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0, downloadRate: Double = 0, uploadRate: Double = 0, seedRatio: Double? = 1, swarm: SwarmCounts = .init(), error: String? = nil, trackers: [String] = []) {
        self.id = id; self.name = name; self.destination = destination; self.isMultiFile = isMultiFile; self.state = state; self.files = files; self.fileUploadHistoryComplete = fileUploadHistoryComplete; self.completedBytes = completedBytes; self.selectedBytes = selectedBytes; self.downloadedBytes = downloadedBytes; self.uploadedBytes = uploadedBytes; self.downloadRate = downloadRate; self.uploadRate = uploadRate; self.seedRatio = seedRatio; self.swarm = swarm; self.error = error; self.trackers = trackers
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var output = Data(); var index = hex.startIndex
        while index < hex.endIndex { let end = hex.index(index, offsetBy: 2); guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }; output.append(byte); index = end }
        self = output
    }
}
