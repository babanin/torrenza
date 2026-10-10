import Foundation
import XCTest
import TorrentCore
@testable import TorrentEngine

extension EngineTests {
    func testHighThroughputSettingsPersistAndRestoreTheirBudget() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = TorrentEngine(stateDirectory: directory)
        var settings = EngineSettings()
        settings.maxDownloads = 5
        settings.maxSeeds = 3
        settings.downloadLimit = 456_789
        settings.uploadLimit = 12_345
        settings.storageProfile = .hdd
        settings.destinationProfiles["/Volumes/Fixture"] = .ssd
        settings.preventIdleSleep = true
        settings.apply(.highThroughput)
        await engine.updateSettings(settings)
        try await engine.shutdownForProfileSwitch()

        let restored = TorrentEngine(stateDirectory: directory)
        let initialBudget = await restored.budget
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        let actual = await restored.settings()
        let restoredBudget = await restored.budget
        let limit = await restoredBudget.limit
        let headroom = await restoredBudget.verificationHeadroom
        XCTAssertEqual(actual, settings)
        XCTAssertTrue(initialBudget === restoredBudget, "Restore must resize the shared budget instead of replacing it")
        XCTAssertEqual(limit, 256 * 1024 * 1024)
        XCTAssertEqual(headroom, 1024 * 1024)
        try await restored.shutdownForProfileSwitch()
    }

    func testLegacyArchiveRetainsConnectionLimitAndEightRequests() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"{"version":1,"cleanShutdown":true,"settings":{"maxPeers":125,"payloadBudget":33554432,"storageProfile":"hdd","downloadLimit":123456},"records":[]}"#.utf8)
        try legacy.write(to: directory.appendingPathComponent("transfers.json"))
        let engine = TorrentEngine(stateDirectory: directory)
        try await engine.prepareForActivation()
        try await engine.activatePreparedProfile()
        let settings = await engine.settings()
        let limit = await engine.budget.limit
        XCTAssertEqual(settings.maxPeers, 125)
        XCTAssertEqual(settings.downloadRequestWindow, 8)
        XCTAssertEqual(settings.payloadBudget, 32 * 1024 * 1024)
        XCTAssertEqual(settings.downloadLimit, 123_456)
        XCTAssertEqual(settings.storageProfile, .hdd)
        XCTAssertEqual(limit, settings.payloadBudget)
        try await engine.shutdownForProfileSwitch()
    }

    func testLiveSettingsResizeSameBudgetAndRetainOutstandingReservations() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = TorrentEngine(stateDirectory: directory)
        let originalBudget = await engine.budget
        let initialReservation = 31 * 1024 * 1024
        try await originalBudget.acquire(initialReservation)
        var settings = EngineSettings()
        settings.apply(.highThroughput)
        await engine.updateSettings(settings)
        let increasedBudget = await engine.budget
        XCTAssertTrue(originalBudget === increasedBudget)
        let addedReservation = 64 * 1024 * 1024
        try await originalBudget.acquire(addedReservation)

        settings.apply(.standard)
        await engine.updateSettings(settings)
        let reducedBudget = await engine.budget
        let usedAfterReduction = await originalBudget.used
        let limitAfterReduction = await originalBudget.limit
        let admittedWhileOverLimit = await originalBudget.tryAcquire(1)
        XCTAssertTrue(originalBudget === reducedBudget)
        XCTAssertEqual(usedAfterReduction, initialReservation + addedReservation)
        XCTAssertEqual(limitAfterReduction, 32 * 1024 * 1024)
        XCTAssertFalse(admittedWhileOverLimit)
        await originalBudget.release(addedReservation)
        let admittedIntoHeadroom = await originalBudget.tryAcquire(1)
        XCTAssertFalse(admittedIntoHeadroom, "Payload admission must leave the verification reserve available")
        await originalBudget.release(initialReservation)
        let admittedAfterRelease = await originalBudget.tryAcquire(1)
        XCTAssertTrue(admittedAfterRelease)
        if admittedAfterRelease { await originalBudget.release(1) }
        let remaining = await originalBudget.used
        XCTAssertEqual(remaining, 0)
        try await engine.shutdownForProfileSwitch()
    }
}
