import XCTest
import Foundation
import TorrentCore
@testable import TorrentEngine

extension EngineTests {
    func testMetadataConnectionsShareGlobalAndPerHashAdmissionLimits() async {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let result = await engine.exerciseMetadataAdmissionLimits()
        XCTAssertEqual(result.forHash, min(16, result.ceiling))
        XCTAssertEqual(result.total, min(64, result.ceiling))
        XCTAssertEqual(result.incoming, 0)
        XCTAssertFalse(result.extraAdmitted)
        await engine.shutdown()
    }

    func testMetadataFailureReturnsConnectionAdmission() async {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let link = MagnetLink(infoHash: Data(repeating: 1, count: 20), displayName: nil, trackers: [], peers: [])
        do {
            _ = try await engine.metadata(from: PeerEndpoint(host: "127.0.0.1", port: 0), link: link)
            XCTFail("An invalid endpoint must fail")
        } catch { }
        let admissions = await engine.metadataAdmissionCount()
        XCTAssertEqual(admissions, 0)
        let diagnostics = await engine.diagnostics()
        XCTAssertEqual(diagnostics.budgetUsed, 0)
        await engine.shutdown()
    }

    func testMetadataAtConnectionCapacityFailsWithoutOpeningAnotherSocket() async {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await engine.occupyMetadataCapacity()
        let link = MagnetLink(infoHash: Data(repeating: 2, count: 20), displayName: nil, trackers: [], peers: [])
        do {
            _ = try await engine.metadata(from: PeerEndpoint(host: "127.0.0.1", port: 0), link: link)
            XCTFail("Full connection capacity must reject metadata admission")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("connection capacity"))
        }
        let admissions = await engine.metadataAdmissionCount()
        XCTAssertEqual(admissions, 1)
        await engine.clearMetadataAdmissions()
        await engine.shutdown()
    }
}

private extension TorrentEngine {
    func exerciseMetadataAdmissionLimits() -> (forHash: Int, total: Int, incoming: Int, extraAdmitted: Bool, ceiling: Int) {
        configuration.maxPeers = 1_000
        let hash = Data(repeating: 1, count: 20)
        for _ in 0..<20 { _ = reserveMetadataConnection(infoHash: hash) }
        let forHash = handshakes(for: hash.hexString)
        for index in 2..<100 { _ = reserveMetadataConnection(infoHash: Data(repeating: UInt8(index), count: 20)) }
        let result = (forHash, totalPeers, pendingIncoming,
                      reserveMetadataConnection(infoHash: Data(repeating: 100, count: 20)) != nil,
                      effectivePeerLimit)
        connectionAdmissions.removeAll()
        return result
    }
    func occupyMetadataCapacity() {
        configuration.maxPeers = 1
        _ = reserveMetadataConnection(infoHash: Data(repeating: 1, count: 20))
    }
    func metadataAdmissionCount() -> Int { connectionAdmissions.count }
    func clearMetadataAdmissions() { connectionAdmissions.removeAll() }
}
