import XCTest
import Foundation
import TorrentCore
@testable import TorrentEngine

final class IdleEnergyTests: XCTestCase, @unchecked Sendable {
    func testIdleLibraryStopsTimerAndStillPublishesStateChanges() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-idle-test"))
        let stream = await engine.snapshots()
        var snapshots = stream.makeAsyncIterator()
        let empty = await snapshots.next()
        XCTAssertEqual(empty?.count, 0)
        let initialTimer = await engine.hasTickerForEnergyTest()
        XCTAssertFalse(initialTimer)
        await engine.setActivityForEnergyTest(.downloading)
        let running = await snapshots.next()
        XCTAssertEqual(running?.first?.state, .downloading)
        let runningTimer = await engine.hasTickerForEnergyTest()
        XCTAssertTrue(runningTimer)
        await engine.setActivityForEnergyTest(.paused)
        let paused = await snapshots.next()
        XCTAssertEqual(paused?.first?.state, .paused)
        let pausedTimer = await engine.hasTickerForEnergyTest()
        XCTAssertFalse(pausedTimer)
        await engine.setActivityForEnergyTest(.seeding)
        let resumedTimer = await engine.hasTickerForEnergyTest()
        XCTAssertTrue(resumedTimer)
        await engine.setActivityForEnergyTest(.completed)
        let completedTimer = await engine.hasTickerForEnergyTest()
        XCTAssertFalse(completedTimer)
    }
}

extension TorrentEngine {
    fileprivate func hasTickerForEnergyTest() -> Bool { ticker != nil }
    fileprivate func setActivityForEnergyTest(_ state: TransferState) {
        if sessions["test"] == nil {
            let meta = TorrentMetainfo(infoHash: Data(repeating: 0, count: 20), rawInfo: Data(), name: "test", pieceLength: 1, pieceHashes: [Data(repeating: 0, count: 20)], files: [TorrentFile(index: 0, path: ["test"], length: 1, offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
            let record = EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/tmp"), selectedFiles: [0], seedRatio: 0, downloaded: 0, uploaded: 0, wantedRunning: true, verified: PieceBitset(count: 1))
            sessions["test"] = EngineSession(record: record)
        }
        sessions["test"]?.snapshot.state = state
        updateActivity()
    }
}
