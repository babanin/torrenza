import XCTest
import Foundation
import CryptoKit
import TorrentCore
@testable import TorrentEngine

final class EngineTests: XCTestCase, @unchecked Sendable {
    func fixture(_ payload: Data, name: String = "payload.bin") -> TorrentMetainfo {
        let pieceLength = 32_768
        let hashes = stride(from: 0, to: payload.count, by: pieceLength).map { Data(Insecure.SHA1.hash(data: payload.subdata(in: $0..<min($0 + pieceLength, payload.count)))) }
        let hash = Data(Insecure.SHA1.hash(data: Data(name.utf8) + payload))
        return TorrentMetainfo(infoHash: hash, rawInfo: Data("de".utf8), name: name, pieceLength: pieceLength, pieceHashes: hashes, files: [TorrentFile(index: 0, path: [name], length: Int64(payload.count), offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-engine-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func waitFor(_ engine: TorrentEngine, id: String, state: TransferState, timeout: TimeInterval = 12) async throws -> TransferSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = await engine.currentSnapshots().first(where: { $0.id == id && $0.state == state }) { return snapshot }
            try await Task.sleep(for: .milliseconds(50))
        }
        let latest = await engine.currentSnapshots()
        XCTFail("Transfer did not enter \(state): \(latest)")
        throw TorrentError.network("Test transfer timeout")
    }

    func testLoopbackDownloadAndInboundVerifiedSeeding() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let payload = Data((0..<262_151).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let meta = fixture(payload)
        try payload.write(to: source.appendingPathComponent(meta.name))
        let seed = TorrentEngine(stateDirectory: root.appendingPathComponent("seed-state"))
        let client = TorrentEngine(stateDirectory: root.appendingPathComponent("client-state"))
        do {
            _ = try await seed.add(metainfo: meta, destination: source, selectedFiles: [0], seedRatio: nil, allowExisting: true)
            _ = try await waitFor(seed, id: meta.id, state: .seeding)
            let port = await seed.listenPort()
            XCTAssertGreaterThan(port, 0)
            _ = try await client.add(metainfo: meta, destination: target, selectedFiles: [0], seedRatio: 0)
            await client.addCandidates(meta.id, [PeerEndpoint(host: "127.0.0.1", port: port)])
            await client.connectCandidates(meta.id)
            let result = try await waitFor(client, id: meta.id, state: .completed)
            XCTAssertEqual(result.completedBytes, Int64(payload.count))
            XCTAssertEqual(result.downloadedBytes, Int64(payload.count))
            let statistics = await client.statistics()
            XCTAssertEqual(statistics.current.downloadedBytes, Int64(payload.count))
            XCTAssertEqual(statistics.lifetimeDownloadedBytes, Int64(payload.count))
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(meta.name)), payload)
            let seedSnapshots = await seed.currentSnapshots()
            XCTAssertGreaterThan(seedSnapshots.first?.uploadedBytes ?? 0, 0)
            try await client.remove(meta.id)
            let afterRemoval = await client.statistics()
            XCTAssertEqual(afterRemoval.lifetimeDownloadedBytes, Int64(payload.count))
            await client.shutdown(); await seed.shutdown()
            let restored = TorrentEngine(stateDirectory: root.appendingPathComponent("client-state"))
            await restored.restore()
            let restoredStatistics = await restored.statistics()
            XCTAssertEqual(restoredStatistics.current.downloadedBytes, 0)
            XCTAssertEqual(restoredStatistics.lifetimeDownloadedBytes, Int64(payload.count))
            let history = try await restored.sessionHistory()
            XCTAssertEqual(history.count, 2)
            XCTAssertNotNil(history.first(where: { $0.id == statistics.current.id })?.endedAt)
            await restored.shutdown()
        } catch { await client.shutdown(); await seed.shutdown(); throw error }
    }

    func testResumeRechecksModifiedFilesAndPreservesPause() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let payload = Data(repeating: 42, count: 65_536), meta = fixture(Data(repeating: 42, count: 65_536))
        try payload.write(to: target.appendingPathComponent(meta.name))
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        _ = try await engine.add(metainfo: meta, destination: target, selectedFiles: [0], seedRatio: 0, allowExisting: true)
        await engine.pause(meta.id)
        await engine.shutdown()
        var changed = payload; changed[0] = 0
        try changed.write(to: target.appendingPathComponent(meta.name))
        let restored = TorrentEngine(stateDirectory: state)
        await restored.restore()
        let result = await restored.currentSnapshots().first
        XCTAssertEqual(result?.state, .paused)
        XCTAssertEqual(result?.completedBytes, 32_768)
        await restored.shutdown()
    }

    func testBandwidthChangeReleasesPendingRequests() async throws {
        let limiter = TransferRateLimiter()
        await limiter.configure(download: 1, upload: 0)
        try await limiter.wait(bytes: 16_384, upload: false)
        let pending = Task { try await limiter.wait(bytes: 16_384, upload: false) }
        try await Task.sleep(for: .milliseconds(20))
        await limiter.configure(download: 0, upload: 0)
        try await pending.value
    }

    func testLegacyMigrationAndUIUseOneSQLiteFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let meta = fixture(Data(repeating: 1, count: 32_768))
        let record = EngineRecord(metainfo: meta, destination: root, bookmark: nil, selectedFiles: [0], seedRatio: 0, downloaded: 32_768, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: 1, repeating: true))
        let archive = EngineArchive(cleanShutdown: true, settings: EngineSettings(), records: [record])
        try JSONEncoder().encode(archive).write(to: state.appendingPathComponent("transfers.json"))
        let persistence = EnginePersistence(directory: state)
        let migrated = try await persistence.load()
        XCTAssertEqual(migrated?.records.first?.metainfo, meta)
        XCTAssertEqual(migrated?.records.first?.downloaded, 32_768)
        let current = SessionStatistics()
        var statistics = try await persistence.startSession(current)
        XCTAssertEqual(statistics.current.downloadedBytes, 0)
        XCTAssertEqual(statistics.lifetimeDownloadedBytes, 32_768)
        statistics.current.downloadedBytes = 5; statistics.lifetimeDownloadedBytes += 5
        try await persistence.save(EngineArchive(settings: EngineSettings(), records: []), statistics: statistics)
        let nextPersistence = EnginePersistence(directory: state)
        _ = try await nextPersistence.load()
        let nextRun = try await nextPersistence.startSession(SessionStatistics())
        XCTAssertEqual(nextRun.lifetimeDownloadedBytes, 32_773)
        XCTAssertEqual(nextRun.current.downloadedBytes, 0)
        let history = try await nextPersistence.sessionHistory()
        XCTAssertEqual(history.first(where: { $0.id == current.id })?.interrupted, true)
        let ui = Data("{\"expanded\":[\"storage\"]}".utf8)
        try await persistence.saveUIState(ui)
        let savedUI = try await persistence.loadUIState()
        XCTAssertEqual(savedUI, ui)
        let names = try FileManager.default.contentsOfDirectory(atPath: state.path)
        XCTAssertEqual(names, ["Torrenza.sqlite"])
    }

    func testUnreadableLegacyArchiveIsPreserved() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = Data("invalid saved state".utf8)
        let legacy = root.appendingPathComponent("transfers.json")
        try sentinel.write(to: legacy)
        let engine = TorrentEngine(stateDirectory: root)
        await engine.restore()
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first?.id, "library-error")
        await engine.shutdown()
        XCTAssertEqual(try Data(contentsOf: legacy), sentinel)
    }

    func testReselectOwnedFilesAndRemoveAllManagedSelections() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = fixture(Data(repeating: 7, count: 65_536))
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: Data("de".utf8), name: "files", pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [TorrentFile(index: 0, path: ["files", "first"], length: 32_768, offset: 0), TorrentFile(index: 1, path: ["files", "second"], length: 32_768, offset: 32_768)], trackerTiers: [], isPrivate: true, isMultiFile: true)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0, 1], seedRatio: 0)
        await engine.pause(meta.id)
        try await engine.setSelectedFiles(meta.id, selectedFiles: [0])
        try await engine.setSelectedFiles(meta.id, selectedFiles: [1])
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first?.state, .paused)
        let unrelated = root.appendingPathComponent("files/unrelated")
        try Data("keep".utf8).write(to: unrelated)
        try await engine.remove(meta.id, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("files/first").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("files/second").path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        await engine.shutdown()
    }

    func testSelectionDoesNotClaimWholeTorrentComplete() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 7, count: 65_536)
        let base = fixture(payload)
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: Data("de".utf8), name: "files", pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [TorrentFile(index: 0, path: ["files", "first"], length: 32_768, offset: 0), TorrentFile(index: 1, path: ["files", "second"], length: 32_768, offset: 32_768)], trackerTiers: [], isPrivate: true, isMultiFile: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        try payload.prefix(32_768).write(to: root.appendingPathComponent("files/first"))
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: 0, allowExisting: true)
        let result = await engine.currentSnapshots().first
        XCTAssertEqual(result?.state, .completed)
        let wholeComplete = await engine.isWholeCompleteForTest(meta.id)
        XCTAssertFalse(wholeComplete)
        await engine.shutdown()
    }
}

extension TorrentEngine {
    func isWholeCompleteForTest(_ id: String) -> Bool { sessions[id]?.record.verified.isComplete ?? false }
}
