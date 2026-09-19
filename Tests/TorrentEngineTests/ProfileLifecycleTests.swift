import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    func testExpandingRestoredSelectionDoesNotRecreateMissingOwnedPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = fixture(Data(repeating: 42, count: 65_536), name: "bundle")
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: base.rawInfo, name: base.name, pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [
            TorrentFile(index: 0, path: ["bundle", "first.bin"], length: 32_768, offset: 0),
            TorrentFile(index: 1, path: ["bundle", "second.bin"], length: 32_768, offset: 32_768)
        ], trackerTiers: [], isPrivate: true, isMultiFile: true)
        let state = root.appendingPathComponent("state")
        let first = TorrentEngine(stateDirectory: state)
        _ = try await first.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
        try await first.shutdownForProfileSwitch()
        let firstURL = root.appendingPathComponent("bundle/first.bin")
        try FileManager.default.removeItem(at: firstURL)

        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        do {
            try await restored.setSelectedFiles(meta.id, selectedFiles: [0, 1])
            XCTFail("Missing existing data must fail before creating newly selected files")
        } catch { }
        let snapshot = await restored.currentSnapshots().first
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertNotNil(snapshot?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle/second.bin").path))
        try await restored.shutdownForProfileSwitch()
    }

    func testRestoredPausedTorrentCanDeleteItsOwnedFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768)
        let meta = fixture(payload)
        let payloadURL = root.appendingPathComponent(meta.name)
        let unrelatedURL = root.appendingPathComponent("unrelated.txt")
        try payload.write(to: payloadURL)
        try Data("Keep me".utf8).write(to: unrelatedURL)
        let state = root.appendingPathComponent("state")
        let first = TorrentEngine(stateDirectory: state)
        _ = try await first.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, allowExisting: true, startPaused: true)
        try await first.shutdownForProfileSwitch()

        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let diskOpened = await restored.hasOpenPayloadForProfileTest(meta.id)
        XCTAssertFalse(diskOpened)
        try await restored.remove(meta.id, deleteFiles: true)
        let snapshots = await restored.currentSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), Data("Keep me".utf8))
        try await restored.shutdownForProfileSwitch()
    }

    func testInterruptedProfileRestoresSavedProgressWithoutOpeningPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data(repeating: 42, count: 65_536))
        let changedPayload = Data(repeating: 0, count: 65_536)
        try changedPayload.write(to: root.appendingPathComponent(meta.name))
        var verified = PieceBitset(count: meta.pieceHashes.count)
        verified[0] = true
        let record = EngineRecord(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, downloaded: 32_768, uploaded: 17, wantedRunning: false, verified: verified)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        try await engine.persistence.save(EngineArchive(cleanShutdown: false, settings: EngineSettings(), records: [record]))
        try await engine.prepareForActivation()
        try await engine.activatePreparedProfile()
        let snapshot = await engine.currentSnapshots().first
        let diskOpened = await engine.hasOpenPayloadForProfileTest(meta.id)
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertEqual(snapshot?.completedBytes, 32_768)
        XCTAssertEqual(snapshot?.files.first?.verifiedBytes, 32_768)
        XCTAssertEqual(snapshot?.downloadedBytes, 32_768)
        XCTAssertEqual(snapshot?.uploadedBytes, 17)
        XCTAssertFalse(diskOpened)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(meta.name)), changedPayload)
        try await engine.shutdownForProfileSwitch()
    }

    func testMissingPausedPayloadIsDeferredUntilStartAndThenQuarantined() async throws {
        for cleanShutdown in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let meta = fixture(Data(repeating: 42, count: 65_536))
            var verified = PieceBitset(count: meta.pieceHashes.count)
            for piece in 0..<verified.count { verified[piece] = true }
            let record = EngineRecord(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, downloaded: 65_536, uploaded: 0, wantedRunning: false, verified: verified)
            let state = root.appendingPathComponent("state")
            let engine = TorrentEngine(stateDirectory: state)
            try await engine.persistence.save(EngineArchive(cleanShutdown: cleanShutdown, settings: EngineSettings(), records: [record]))
            try await engine.prepareForActivation()
            try await engine.activatePreparedProfile()
            let snapshot = await engine.currentSnapshots().first
            let diskOpened = await engine.hasOpenPayloadForProfileTest(meta.id)
            XCTAssertEqual(snapshot?.state, .paused)
            XCTAssertEqual(snapshot?.completedBytes, 65_536)
            XCTAssertNil(snapshot?.error)
            XCTAssertFalse(diskOpened)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meta.name).path))

            await engine.start(meta.id)
            let failed = await engine.currentSnapshots().first
            XCTAssertEqual(failed?.state, .failed)
            XCTAssertNotNil(failed?.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meta.name).path))
            try await engine.shutdownForProfileSwitch()

            let restored = TorrentEngine(stateDirectory: state)
            try await restored.prepareForActivation()
            try await restored.activatePreparedProfile()
            let quarantined = await restored.currentSnapshots().first
            XCTAssertEqual(quarantined?.state, .failed)
            XCTAssertEqual(quarantined?.error, failed?.error)
            XCTAssertEqual(quarantined?.completedBytes, 65_536)
            try await restored.shutdownForProfileSwitch()
        }
    }

    func testProfilesIsolateTransfersSettingsStatisticsAndUI() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("first")
        let secondDirectory = root.appendingPathComponent("second")
        let payload = Data(repeating: 42, count: 32_768)
        let meta = fixture(payload)
        try payload.write(to: root.appendingPathComponent(meta.name))
        let first = TorrentEngine(stateDirectory: firstDirectory)
        try await first.prepareForActivation()
        try await first.activatePreparedProfile()
        var settings = EngineSettings(); settings.downloadLimit = 123_456
        await first.updateSettings(settings)
        let firstUI = Data("{\"filter\":\"paused\"}".utf8)
        try await first.saveUIState(firstUI)
        _ = try await first.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: nil, allowExisting: true)
        let firstSessionID = await first.statistics().current.id
        // A profile boundary must finish pending mutations before persisting totals.
        await first.queueFinalPayloadForProfileTest(downloaded: 23, uploaded: 17)
        let second = TorrentEngine(stateDirectory: secondDirectory)
        try await second.prepareForActivation()
        let beforeActivation = try await second.persistence.sessionHistory()
        XCTAssertTrue(beforeActivation.isEmpty)
        try await first.shutdownForProfileSwitch()
        let backgroundCount = await first.backgroundTasks.count
        let port = await first.listenPort()
        XCTAssertEqual(backgroundCount, 0); XCTAssertEqual(port, 0)
        try await second.activatePreparedProfile()
        let secondSnapshots = await second.currentSnapshots()
        let secondSettings = await second.settings()
        let secondStatistics = await second.statistics()
        let secondUI = try await second.loadUIState()
        XCTAssertTrue(secondSnapshots.isEmpty)
        XCTAssertEqual(secondSettings.downloadLimit, 0)
        XCTAssertEqual(secondStatistics.lifetimeDownloadedBytes, 0)
        XCTAssertNil(secondUI)
        try await second.saveUIState(Data("second".utf8))
        try await second.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: firstDirectory)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let restoredUI = try await restored.loadUIState()
        let restoredSettings = await restored.settings()
        let restoredStats = await restored.statistics()
        let history = try await restored.sessionHistory()
        XCTAssertEqual(restoredUI, firstUI)
        XCTAssertEqual(restoredSettings.downloadLimit, 123_456)
        XCTAssertEqual(restoredStats.current.downloadedBytes, 0)
        XCTAssertEqual(restoredStats.lifetimeDownloadedBytes, 23)
        XCTAssertEqual(restoredStats.lifetimeUploadedBytes, 17)
        XCTAssertNotNil(history.first(where: { $0.id == firstSessionID })?.endedAt)
        XCTAssertEqual(history.first(where: { $0.id == firstSessionID })?.interrupted, false)
        let snapshot = try await waitFor(restored, id: meta.id, state: .seeding)
        XCTAssertEqual(snapshot.completedBytes, 32_768)
        try await restored.shutdownForProfileSwitch()
    }

    func testCorruptProfilePreflightPreservesDatabaseAndDoesNotStartSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStore(url: root.appendingPathComponent("Torrenza.sqlite"))
        let corrupt = Data("invalid header".utf8)
        try await store.write([SQLiteEntry(namespace: "engine", key: "settings", value: corrupt)])
        let engine = TorrentEngine(stateDirectory: root)
        do { try await engine.prepareForActivation(); XCTFail("Corrupt profile should fail preflight") }
        catch { }
        await engine.shutdown()
        let unchanged = try await store.read(namespace: "engine", key: "settings")
        let sessions = try await store.readAll(namespace: "sessions")
        XCTAssertEqual(unchanged, corrupt)
        XCTAssertTrue(sessions.isEmpty)
        try await store.close()
    }

    func testFailedProfileCheckpointCanBeRetriedWithoutLosingSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentEngine(stateDirectory: root)
        try await engine.prepareForActivation()
        try await engine.activatePreparedProfile()
        await engine.recordPayloadForProfileTest(downloaded: 19, uploaded: 7)
        let original = root.appendingPathComponent("Torrenza.sqlite")
        let backup = root.appendingPathComponent("saved.sqlite")
        try await engine.persistence.close()
        try FileManager.default.moveItem(at: original, to: backup)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        do { try await engine.shutdownForProfileSwitch(); XCTFail("Checkpoint should fail") }
        catch { }
        let afterFailure = await engine.statistics()
        XCTAssertNil(afterFailure.current.endedAt)
        XCTAssertEqual(afterFailure.current.downloadedBytes, 19)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: backup, to: original)
        await engine.resumeAfterFailedProfileSwitch()
        try await engine.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: root)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let statistics = await restored.statistics()
        XCTAssertEqual(statistics.lifetimeDownloadedBytes, 19)
        XCTAssertEqual(statistics.lifetimeUploadedBytes, 7)
        try await restored.shutdownForProfileSwitch()
    }
}

extension TorrentEngine {
    func hasOpenPayloadForProfileTest(_ id: String) -> Bool {
        sessions[id]?.disk != nil
    }

    func queueFinalPayloadForProfileTest(downloaded: Int64, uploaded: Int64) {
        startBackgroundTask { engine in
            // Mimics an in-flight network send completing as cancellation lands.
            try? await Task.sleep(for: .seconds(60))
            engine.recordPayloadForProfileTest(downloaded: downloaded, uploaded: uploaded)
        }
    }
    func recordPayloadForProfileTest(downloaded: Int64, uploaded: Int64) {
        runStatistics.current.downloadedBytes += downloaded
        runStatistics.current.uploadedBytes += uploaded
        runStatistics.lifetimeDownloadedBytes += downloaded
        runStatistics.lifetimeUploadedBytes += uploaded
    }
}
