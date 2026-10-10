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

extension PieceSchedulingTests {
    func testAvailabilityCountsAndSeedPromotionAreIncremental() throws {
        let session = pickerSession(count: 4)
        let key = UUID()
        session.peers[key] = try pickerPeer(count: 4)
        var bits = PieceBitset(count: 4)
        bits[0] = true; bits[2] = true
        session.replacePeerAvailability(key: key, availability: bits)
        XCTAssertEqual(session.picker.availability, [1, 0, 1, 0])
        session.recordPeerHave(key: key, index: 2)
        XCTAssertEqual(session.picker.availability, [1, 0, 1, 0], "Duplicate HAVE must not inflate rarity")
        session.recordPeerHave(key: key, index: 1)
        session.recordPeerHave(key: key, index: 3)
        XCTAssertEqual(session.picker.seedCount, 1)
        XCTAssertEqual(session.picker.availability, [0, 0, 0, 0])
        XCTAssertTrue(session.peers[key]!.isSeed)
        session.replacePeerAvailability(key: key, availability: bits)
        XCTAssertEqual(session.picker.seedCount, 0)
        XCTAssertEqual(session.picker.availability, [1, 0, 1, 0])
        session.removePeerAvailability(session.peers.removeValue(forKey: key)!)
        XCTAssertEqual(session.picker.availability, [0, 0, 0, 0])
    }

    func testPickerRotationRarityAndOpenPiecePriority() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-rotating-picker-test"))
        let result = try await engine.exercisePickerRotation()
        XCTAssertEqual(result.first, 5)
        XCTAssertEqual(result.open, 5)
        XCTAssertEqual(result.rotated, 900)
        XCTAssertTrue(result.wrap < 100)
    }

    func testEqualRarityTiesSpreadRequests() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-tie-picker-test"))
        let choices = try await engine.exerciseEqualRarityTies()
        XCTAssertGreaterThan(choices.count, 8)
    }

    func testHDDLocalityAndCompletionBacklogBound() async throws {
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-local-picker-test"))
        let result = try await engine.exerciseLocalPicker()
        XCTAssertEqual(result.indices, Array(0..<16))
        XCTAssertTrue(result.blocked)
        XCTAssertEqual(result.reopened, 16)
        XCTAssertEqual(result.afterReset, 0)
    }
}

private func pickerSession(count: Int, pieceLength: Int = 32_768) -> EngineSession {
    let half = count / 2
    let meta = TorrentMetainfo(infoHash: Data(repeating: 1, count: 20), rawInfo: Data(), name: "picker", pieceLength: pieceLength, pieceHashes: Array(repeating: Data(repeating: 0, count: 20), count: count), files: [TorrentFile(index: 0, path: ["first"], length: Int64(half * pieceLength), offset: 0), TorrentFile(index: 1, path: ["second"], length: Int64((count - half) * pieceLength), offset: Int64(half * pieceLength))], trackerTiers: [], isPrivate: true, isMultiFile: true)
    return EngineSession(record: EngineRecord(metainfo: meta, destination: URL(fileURLWithPath: "/tmp"), selectedFiles: [0, 1], seedRatio: 0, downloaded: 0, uploaded: 0, wantedRunning: true, verified: PieceBitset(count: count)))
}

private func pickerPeer(count: Int, complete: Bool = false) throws -> ActivePeer {
    let endpoint = PeerEndpoint(host: "127.0.0.1", port: 1)
    return ActivePeer(connection: try PeerConnection(endpoint: endpoint), endpoint: endpoint, availability: PieceBitset(count: count, repeating: complete))
}

extension TorrentEngine {
    fileprivate func exercisePickerRotation() throws -> (first: Int?, open: Int?, rotated: Int?, wrap: Int) {
        configuration.storageProfile = .ssd
        let session = pickerSession(count: 1_024)
        let peer = try pickerPeer(count: 1_024, complete: true)
        session.picker.cursor = 0
        session.picker.availability = Array(repeating: 2, count: 1_024)
        session.picker.availability[5] = 1
        let first = nextBlock(session, peer: peer)
        session.pieceWork[first!.piece]?.requested.insert(first!.begin)
        let open = nextBlock(session, peer: peer)
        session.clearPieceWork()
        session.picker.cursor = 800
        session.picker.availability[900] = 0
        let rotated = nextBlock(session, peer: peer)
        session.clearPieceWork()
        session.picker.cursor = 1_000
        session.picker.availability[12] = 0
        // Hide the earlier rare candidate to make the wrap selection unambiguous.
        session.record.verified[900] = true
        return (first?.piece, open?.piece, rotated?.piece, nextBlock(session, peer: peer)!.piece)
    }

    fileprivate func exerciseEqualRarityTies() throws -> Set<Int> {
        configuration.storageProfile = .ssd
        let session = pickerSession(count: 32, pieceLength: 16_384)
        let peer = try pickerPeer(count: 32, complete: true)
        session.picker.randomState = 1
        var choices: Set<Int> = []
        for _ in 0..<64 {
            session.picker.cursor = 0
            let request = nextBlock(session, peer: peer)!
            choices.insert(request.piece)
            session.removePieceWork(request.piece)
        }
        return choices
    }

    fileprivate func exerciseLocalPicker() throws -> (indices: [Int], blocked: Bool, reopened: Int?, afterReset: Int?) {
        configuration.storageProfile = .hdd
        let session = pickerSession(count: 100, pieceLength: 16_384)
        let peer = try pickerPeer(count: 100, complete: true)
        var indices: [Int] = []
        for _ in 0..<16 {
            let request = nextBlock(session, peer: peer)!
            indices.append(request.piece)
            session.pieceWork[request.piece]?.requested.insert(request.begin)
        }
        let blocked = nextBlock(session, peer: peer) == nil
        session.record.verified[3] = true
        session.removePieceWork(3)
        let reopened = nextBlock(session, peer: peer)?.piece
        session.clearPieceWork()
        let afterReset = nextBlock(session, peer: peer)?.piece
        return (indices, blocked, reopened, afterReset)
    }
}

extension PieceSchedulingTests {
    /// Explicitly opt in so ordinary correctness runs do not become timing runs.
    /// Run with TORRENZA_PICKER_BENCHMARK=1 swift test -c release --filter testThousandPeerPickerBenchmark.
    func testThousandPeerPickerBenchmark() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TORRENZA_PICKER_BENCHMARK"] != "1", "Opt-in optimized picker benchmark")
        let engine = TorrentEngine(stateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-picker-benchmark"))
        let result = try await engine.benchmarkThousandPeerPicker()
        XCTAssertEqual(result.peers, 1_000)
        XCTAssertGreaterThan(result.checksum, 0)
        print(String(format: "PICKER BENCHMARK peers=%d pieces=16384 samples=200 legacy_ms=%.3f indexed_ms=%.3f checksum=%d", result.peers, result.legacy * 1_000, result.indexed * 1_000, result.checksum))
    }
}

extension TorrentEngine {
    fileprivate func benchmarkThousandPeerPicker() throws -> (peers: Int, legacy: Double, indexed: Double, checksum: Int) {
        configuration.storageProfile = .ssd
        let count = 16_384
        let session = pickerSession(count: count, pieceLength: 16_384)
        let peer = try pickerPeer(count: count, complete: true)
        let empty = try pickerPeer(count: count)
        var even = PieceBitset(count: count), odd = PieceBitset(count: count)
        for index in 0..<count {
            if index % 2 == 0 { even[index] = true }
            else { odd[index] = true }
        }
        for index in 0..<1_000 {
            let key = UUID()
            session.peers[key] = empty
            session.replacePeerAvailability(key: key, availability: index % 5 == 0 ? peer.availability : (index % 2 == 0 ? even : odd))
        }
        var checksum = 0
        let legacyStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<200 {
            let inFlight = PieceBitset(count: count)
            let candidates = PieceBitset.candidates(available: peer.availability, wanted: session.wanted, verified: session.record.verified, inFlight: inFlight)
            var best: Int?, rarity = Int.max, candidate = candidates.firstSetIndex(), inspected = 0
            while let index = candidate, inspected < 256 {
                let available = session.peers.values.reduce(0) { $0 + ($1.availability[index] ? 1 : 0) }
                if available < rarity { best = index; rarity = available }
                candidate = candidates.firstSetIndex(from: index + 1)
                inspected += 1
            }
            checksum += best! + 1
        }
        let legacy = Date.timeIntervalSinceReferenceDate - legacyStart
        let indexedStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<200 {
            let request = nextBlock(session, peer: peer)!
            checksum += request.piece + 1
            session.removePieceWork(request.piece)
        }
        return (session.peers.count, legacy, Date.timeIntervalSinceReferenceDate - indexedStart, checksum)
    }
}
