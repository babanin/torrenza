import XCTest
import Foundation
import TorrentCore
import TorrentWire
@testable import TorrentEngine

final class PieceSchedulingTests: XCTestCase, @unchecked Sendable {
    func testLargePieceCursorAndDisconnectedHole() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-scheduling-test"))
        let result = try await engine.exerciseLargePieceCursor()
        XCTAssertEqual(result.scheduled, 65_536)
        XCTAssertTrue(result.saturated)
        XCTAssertEqual(result.recovered, 16_384 * 23)
    }
}

extension TorrentEngine {
    fileprivate func exerciseLargePieceCursor() throws -> (scheduled: Int, saturated: Bool, recovered: Int?) {
        let length = 1_073_741_824
        let meta = TorrentMetainfo(infoHash: Data(repeating: 1, count: 20), rawInfo: Data(), name: "huge-piece", pieceLength: length, pieceHashes: [Data(repeating: 0, count: 20)], files: [TorrentFile(index: 0, path: ["huge-piece"], length: Int64(length), offset: 0)], trackerTiers: [], isPrivate: true, isMultiFile: false)
        let record = EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/tmp"), selectedFiles: [0], seedRatio: 0, downloaded: 0, uploaded: 0, wantedRunning: true, verified: PieceBitset(count: 1))
        let session = EngineSession(record: record)
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
        // Constructing PeerConnection does not open a socket until start/connect.
        let peer = ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: 1, repeating: true))
        var scheduled = 0
        for index in 0..<65_536 {
            guard let request = nextBlock(session, peer: peer), request.begin == index * 16_384 else {
                throw TorrentError.invalidMessage("Piece cursor skipped or duplicated a block")
            }
            session.pieceWork[0]?.requested.insert(request.begin)
            scheduled += 1
        }
        let saturated = nextBlock(session, peer: peer) == nil
        session.pieceWork[0]?.requested.remove(16_384 * 23)
        let recovered = nextBlock(session, peer: peer)?.begin
        return (scheduled, saturated, recovered)
    }
}
