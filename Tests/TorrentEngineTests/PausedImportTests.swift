import XCTest
import Foundation
import CryptoKit
import TorrentCore
@testable import TorrentEngine

extension EngineTests {
    func testQBittorrentBackupImportsSelectedPayloadWithHistoryAndPause() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("BT_backup")
        let destination = root.appendingPathComponent("downloads")
        let folder = destination.appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skipped = Data(repeating: 7, count: 32_768)
        let selected = Data(repeating: 42, count: 32_768)
        let pieceHashes = Data(Insecure.SHA1.hash(data: skipped)) + Data(Insecure.SHA1.hash(data: selected))
        func bytes(_ value: String) -> BencodeValue { .bytes(Data(value.utf8)) }
        let torrent = Bencode.encode(.dictionary(["info": .dictionary([
            "name": bytes("collection"), "private": .integer(1),
            "piece length": .integer(32_768), "pieces": .bytes(pieceHashes),
            "files": .list([
                .dictionary(["length": .integer(32_768), "path": .list([bytes("skipped.bin")])]),
                .dictionary(["length": .integer(32_768), "path": .list([bytes("selected.bin")])])
            ])
        ])]))
        let metainfo = try MetainfoParser.parse(torrent)
        let torrentURL = backup.appendingPathComponent(metainfo.id + ".torrent")
        let resumeURL = backup.appendingPathComponent(metainfo.id + ".fastresume")
        let resume = Bencode.encode(.dictionary([
            "info-hash": .bytes(metainfo.infoHash), "save_path": bytes(destination.path),
            "qBt-contentLayout": bytes("Original"),
            "file_priority": .list([.integer(0), .integer(7)]),
            "qBt-ratioLimit": .integer(1500),
            "total_downloaded": .integer(65_536), "total_uploaded": .integer(16_384)
        ]))
        try torrent.write(to: torrentURL)
        try resume.write(to: resumeURL)
        let selectedURL = folder.appendingPathComponent("selected.bin")
        try selected.write(to: selectedURL)

        let rows = try QBittorrentImport.scan(directory: backup)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.issue)
        let payload = try QBittorrentImport.load(candidate: row)
        try QBittorrentImport.preflight(payload: payload)
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        do {
            _ = try await engine.add(metainfo: payload.metainfo, destination: try XCTUnwrap(row.destination), selectedFiles: row.selectedFiles, seedRatio: row.seedRatio, allowExisting: true, startPaused: true, downloadedBytes: row.downloadedBytes, uploadedBytes: row.uploadedBytes)
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.state, .paused)
            XCTAssertEqual(result?.files.filter(\.selected).map(\.id), [1])
            XCTAssertEqual(result?.selectedBytes, 32_768)
            XCTAssertEqual(result?.completedBytes, 32_768)
            XCTAssertEqual(result?.downloadedBytes, 65_536)
            XCTAssertEqual(result?.uploadedBytes, 16_384)
            XCTAssertEqual(result?.seedRatio, 1.5)
            XCTAssertEqual(try Data(contentsOf: selectedURL), selected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("skipped.bin").path))
            XCTAssertEqual(try Data(contentsOf: torrentURL), torrent)
            XCTAssertEqual(try Data(contentsOf: resumeURL), resume)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }

        let restored = TorrentEngine(stateDirectory: state)
        await restored.restore()
        let result = await restored.currentSnapshots().first
        XCTAssertEqual(result?.state, .paused)
        XCTAssertEqual(result?.files.filter(\.selected).map(\.id), [1])
        XCTAssertEqual(result?.completedBytes, 32_768)
        XCTAssertEqual(result?.downloadedBytes, 65_536)
        XCTAssertEqual(result?.uploadedBytes, 16_384)
        await restored.shutdown()
    }

    func testPausedImportVerifiesExistingDataAndPersistsTransferHistory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 65_536)
        let meta = fixture(payload)
        let payloadURL = root.appendingPathComponent(meta.name)
        try payload.write(to: payloadURL)
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], seedRatio: 1, allowExisting: true, startPaused: true, downloadedBytes: 65_536, uploadedBytes: 16_384)
            // Exercise the periodic scheduler explicitly: imports must remain paused
            // even when their preserved ratio would otherwise permit seeding.
            await engine.tick()
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.state, .paused)
            XCTAssertEqual(result?.completedBytes, 65_536)
            XCTAssertEqual(result?.downloadedBytes, 65_536)
            XCTAssertEqual(result?.uploadedBytes, 16_384)
            XCTAssertEqual(result?.downloadRate, 0)
            XCTAssertEqual(result?.uploadRate, 0)
            let port = await engine.listenPort()
            XCTAssertEqual(port, 0)
            let statistics = await engine.statistics()
            XCTAssertEqual(statistics.current.downloadedBytes, 0)
            XCTAssertEqual(statistics.current.uploadedBytes, 0)
            XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }

        let restored = TorrentEngine(stateDirectory: state)
        await restored.restore()
        let result = await restored.currentSnapshots().first
        XCTAssertEqual(result?.state, .paused)
        XCTAssertEqual(result?.completedBytes, 65_536)
        XCTAssertEqual(result?.downloadedBytes, 65_536)
        XCTAssertEqual(result?.uploadedBytes, 16_384)
        await restored.shutdown()
    }

    func testPausedImportKeepsIncompleteDataStoppedAfterVerification() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data(repeating: 42, count: 65_536)
        let meta = fixture(expected)
        var partial = expected
        partial.replaceSubrange(32_768..<65_536, with: Data(repeating: 0, count: 32_768))
        let payloadURL = root.appendingPathComponent(meta.name)
        try partial.write(to: payloadURL)
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
            await engine.tick()
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.state, .paused)
            XCTAssertEqual(result?.completedBytes, 32_768)
            let port = await engine.listenPort()
            XCTAssertEqual(port, 0)
            XCTAssertEqual(try Data(contentsOf: payloadURL), partial)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }
    }

    func testImportRejectsNegativeHistoryBeforeCreatingPayloadOrState() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data(repeating: 42, count: 32_768))
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        for (downloaded, uploaded): (Int64, Int64) in [(-1, 0), (0, -1)] {
            do {
                _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true, downloadedBytes: downloaded, uploadedBytes: uploaded)
                XCTFail("Negative transfer history must be rejected")
            } catch TorrentError.invalidMetainfo { }
            let snapshots = await engine.currentSnapshots()
            XCTAssertTrue(snapshots.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meta.name).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        }
        await engine.shutdown()
    }

    func testTrustedImportSkipsHashingAndPersistsPausedProgress() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data(repeating: 42, count: 65_536)
        let corrupted = Data(repeating: 7, count: expected.count)
        let meta = fixture(expected)
        let payloadURL = root.appendingPathComponent(meta.name)
        try corrupted.write(to: payloadURL)
        let state = root.appendingPathComponent("trusted-state")
        let engine = TorrentEngine(stateDirectory: state)
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true,
                savedVerifiedPieces: PieceBitset(count: 2, repeating: true))
            await engine.tick()
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.state, .paused)
            XCTAssertEqual(result?.completedBytes, 65_536, "Explicitly trusted saved status must not hash payload")
            XCTAssertEqual(try Data(contentsOf: payloadURL), corrupted)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }

        let restored = TorrentEngine(stateDirectory: state)
        await restored.restore()
        let restoredResult = await restored.currentSnapshots().first
        XCTAssertEqual(restoredResult?.state, .paused)
        XCTAssertEqual(restoredResult?.completedBytes, 65_536)
        await restored.shutdown()

        let checked = TorrentEngine(stateDirectory: root.appendingPathComponent("checked-state"))
        do {
            _ = try await checked.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true)
            let checkedResult = await checked.currentSnapshots().first
            XCTAssertEqual(checkedResult?.completedBytes, 0, "Default imports must still detect corrupt pieces")
            await checked.shutdown()
        } catch { await checked.shutdown(); throw error }
    }

    func testTrustedImportUsesPartialSavedBitmap() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 65_536)
        let meta = fixture(payload)
        try payload.write(to: root.appendingPathComponent(meta.name))
        var pieces = PieceBitset(count: 2)
        pieces[1] = true
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: true, startPaused: true, savedVerifiedPieces: pieces)
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.state, .paused)
            XCTAssertEqual(result?.completedBytes, 32_768)
            XCTAssertEqual(result?.files.first?.verifiedBytes, 32_768)
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }
    }

    func testTrustedImportClearsPiecesDependingOnUnselectedPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 65_536)
        let base = fixture(payload)
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: base.rawInfo, name: "collection", pieceLength: base.pieceLength,
            pieceHashes: base.pieceHashes, files: [
                TorrentFile(index: 0, path: ["skipped.bin"], length: 16_384, offset: 0),
                TorrentFile(index: 1, path: ["selected.bin"], length: 49_152, offset: 16_384)
            ], trackerTiers: [], isPrivate: true, isMultiFile: true)
        try Data(payload.suffix(49_152)).write(to: root.appendingPathComponent("selected.bin"))
        let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [1], allowExisting: true, startPaused: true,
                savedVerifiedPieces: PieceBitset(count: 2, repeating: true))
            let result = await engine.currentSnapshots().first
            XCTAssertEqual(result?.completedBytes, 32_768, "Boundary piece needs skipped bytes from a partfile")
            XCTAssertEqual(result?.files.first?.verifiedBytes, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("skipped.bin").path))
            await engine.shutdown()
        } catch { await engine.shutdown(); throw error }
    }

    func testTrustedImportRejectsInvalidModesBeforeCreatingFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data(repeating: 42, count: 32_768))
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        for (existing, paused, count) in [(false, true, 1), (true, false, 1), (true, true, 2)] {
            do {
                _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: existing,
                    startPaused: paused, savedVerifiedPieces: PieceBitset(count: count, repeating: true))
                XCTFail("Invalid trusted import mode must be rejected")
            } catch TorrentError.invalidMetainfo { }
            let snapshots = await engine.currentSnapshots()
            XCTAssertTrue(snapshots.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meta.name).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        }
        await engine.shutdown()
    }

    func testTrustedImportRejectsMissingOrWrongSizedPayloadWithoutChangingFiles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data(repeating: 42, count: 32_768))
        let payloadURL = root.appendingPathComponent(meta.name)
        let state = root.appendingPathComponent("state")
        let engine = TorrentEngine(stateDirectory: state)
        for existing in [false, true] {
            if existing { try Data([42]).write(to: payloadURL) }
            do {
                _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], allowExisting: true,
                    startPaused: true, savedVerifiedPieces: PieceBitset(count: 1, repeating: true))
                XCTFail("Missing or wrong-sized payload must be rejected")
            } catch TorrentError.storage { }
            let snapshots = await engine.currentSnapshots()
            XCTAssertTrue(snapshots.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
            if existing { XCTAssertEqual(try Data(contentsOf: payloadURL), Data([42])) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path)) }
        }
        await engine.shutdown()
    }

}
