import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
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
