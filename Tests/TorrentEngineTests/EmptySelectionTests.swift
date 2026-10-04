import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    func testEmptySelectionImportRemainsMetadataOnlyAcrossRelaunch() async throws {
        for ratio: Double? in [1, nil] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let meta = fixture(Data(repeating: 42, count: 65_536))
            // Missing destinations must not prevent storing a torrent with no payload.
            let destination = root.appendingPathComponent("unmounted-destination")
            let state = root.appendingPathComponent("state")
            let first = TorrentEngine(stateDirectory: state)
            _ = try await first.add(metainfo: meta, destination: destination, selectedFiles: [], seedRatio: ratio, allowExisting: true)
            await first.start(meta.id)
            await first.recheck(meta.id)
            await first.volumesChanged()
            await first.tick()
            try await assertMetadataOnly(first, id: meta.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let saved = try await first.persistence.load()
            let record = try XCTUnwrap(saved?.records.first)
            XCTAssertTrue(record.selectedFiles.isEmpty)
            XCTAssertFalse(record.wantedRunning)
            XCTAssertEqual(record.verified.setCount, 0)
            try await first.shutdownForProfileSwitch()

            let restored = TorrentEngine(stateDirectory: state)
            try await restored.prepareForActivation()
            try await restored.activatePreparedProfile()
            await restored.start(meta.id)
            await restored.recheck(meta.id)
            await restored.volumesChanged()
            try await assertMetadataOnly(restored, id: meta.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try await restored.shutdownForProfileSwitch()
        }
    }

    func testEmptySelectionCanSelectFilesLaterAndExplicitlyStart() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = fixture(Data(repeating: 42, count: 65_536), name: "bundle")
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: base.rawInfo, name: base.name, pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [
            TorrentFile(index: 0, path: ["bundle", "first.bin"], length: 32_768, offset: 0),
            TorrentFile(index: 1, path: ["bundle", "second.bin"], length: 32_768, offset: 32_768)
        ], trackerTiers: [], isPrivate: true, isMultiFile: true)
        let state = root.appendingPathComponent("state")
        let first = TorrentEngine(stateDirectory: state)
        _ = try await first.add(metainfo: meta, destination: destination, selectedFiles: [], seedRatio: nil)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try await first.shutdownForProfileSwitch()
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        try await restored.setSelectedFiles(meta.id, selectedFiles: [1])
        let selectedSnapshots = await restored.currentSnapshots()
        let selected = try XCTUnwrap(selectedSnapshots.first)
        XCTAssertEqual(selected.state, .paused)
        XCTAssertEqual(selected.selectedBytes, 32_768)
        XCTAssertEqual(selected.files.map(\.selected), [false, true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bundle/first.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bundle/second.bin").path))
        await restored.start(meta.id)
        _ = try await waitFor(restored, id: meta.id, state: .downloading)
        try await restored.setSelectedFiles(meta.id, selectedFiles: [])
        let stoppedSnapshots = await restored.currentSnapshots()
        let stopped = try XCTUnwrap(stoppedSnapshots.first)
        XCTAssertEqual(stopped.state, .paused)
        XCTAssertEqual(stopped.selectedBytes, 0)
        XCTAssertEqual(stopped.files.map(\.selected), [false, false])
        let diskOpened = await restored.hasOpenPayloadForProfileTest(meta.id)
        XCTAssertFalse(diskOpened)
        // Deselecting must keep previously owned content available for later use.
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bundle/second.bin").path))
        try await restored.shutdownForProfileSwitch()
        let secondRestore = TorrentEngine(stateDirectory: state)
        try await secondRestore.prepareForActivation()
        try await secondRestore.activatePreparedProfile()
        try await assertMetadataOnly(secondRestore, id: meta.id)
        try await secondRestore.shutdownForProfileSwitch()
    }

    func testReselectingPreviouslyOwnedPayloadDoesNotRecreateOrReplaceIt() async throws {
        for replace in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            let meta = fixture(Data(repeating: 42, count: 32_768))
            let engine = TorrentEngine(stateDirectory: root.appendingPathComponent("state"))
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [0], startPaused: true)
            try await engine.setSelectedFiles(meta.id, selectedFiles: [])
            let payload = root.appendingPathComponent(meta.name)
            let original = root.appendingPathComponent("original.bin")
            // Retain the original inode so a replacement cannot reuse its identity.
            try FileManager.default.moveItem(at: payload, to: original)
            let replacement = Data(repeating: 99, count: 32_768)
            if replace { try replacement.write(to: payload) }
            do {
                try await engine.setSelectedFiles(meta.id, selectedFiles: [0])
                XCTFail("Reselecting lost or replaced managed files must fail")
            } catch { }
            let snapshots = await engine.currentSnapshots()
            let snapshot = try XCTUnwrap(snapshots.first)
            XCTAssertEqual(snapshot.state, .paused)
            XCTAssertTrue(snapshot.files.allSatisfy { !$0.selected })
            if replace { XCTAssertEqual(try Data(contentsOf: payload), replacement) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path)) }
            try await engine.shutdownForProfileSwitch()
        }
    }

    func testInvalidSelectionsRemainRejectedWithoutAffectingOtherTransfers() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let meta = fixture(Data(repeating: 42, count: 32_768))
        let other = fixture(Data(repeating: 17, count: 32_768), name: "other.bin")
        let engine = TorrentEngine(stateDirectory: state)
        _ = try await engine.add(metainfo: other, destination: root, selectedFiles: [0], startPaused: true)
        let otherFile = root.appendingPathComponent(other.name)
        let before = try Data(contentsOf: otherFile)
        do {
            _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [1])
            XCTFail("An invalid index must still be rejected")
        } catch { }
        _ = try await engine.add(metainfo: meta, destination: root, selectedFiles: [])
        do {
            try await engine.setSelectedFiles(meta.id, selectedFiles: [-1])
            XCTFail("An invalid index must still be rejected")
        } catch { }
        await engine.start(meta.id)
        await engine.recheck(meta.id)
        try await assertMetadataOnly(engine, id: meta.id)
        let snapshots = await engine.currentSnapshots()
        XCTAssertEqual(snapshots.first { $0.id == other.id }?.state, .paused)
        XCTAssertEqual(snapshots.first { $0.id == other.id }?.files.first?.selected, true)
        XCTAssertEqual(try Data(contentsOf: otherFile), before)
        try await engine.shutdownForProfileSwitch()
        let archived = try await EnginePersistence(directory: state).load()
        var invalid = try XCTUnwrap(archived)
        let index = try XCTUnwrap(invalid.records.firstIndex { $0.metainfo.id == meta.id })
        invalid.records[index].selectedFiles = [99]
        let invalidState = root.appendingPathComponent("invalid-state")
        try await EnginePersistence(directory: invalidState).save(invalid)
        let invalidEngine = TorrentEngine(stateDirectory: invalidState)
        do {
            try await invalidEngine.prepareForActivation()
            XCTFail("Invalid saved indices must still fail profile preflight")
        } catch { }
        await invalidEngine.shutdown()
    }

    private func assertMetadataOnly(_ engine: TorrentEngine, id: String) async throws {
        let snapshots = await engine.currentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.first { $0.id == id })
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.selectedBytes, 0)
        XCTAssertEqual(snapshot.completedBytes, 0)
        XCTAssertEqual(snapshot.downloadedBytes, 0)
        XCTAssertEqual(snapshot.uploadedBytes, 0)
        XCTAssertTrue(snapshot.files.allSatisfy { !$0.selected })
        XCTAssertNil(snapshot.error)
        let diskOpened = await engine.hasOpenPayloadForProfileTest(id)
        let port = await engine.listenPort()
        XCTAssertFalse(diskOpened)
        XCTAssertEqual(port, 0)
    }
}
