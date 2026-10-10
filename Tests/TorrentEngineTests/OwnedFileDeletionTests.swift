import XCTest
import Foundation
import TorrentCore
import TorrentStorage
@testable import TorrentEngine

extension EngineTests {
    private func deletionRecord(_ meta: TorrentMetainfo, destination: URL, owned: [DiskSignature]?) throws -> EngineRecord {
        var record = EngineRecord(metainfo: meta, destination: destination, selectedFiles: Set(meta.files.map(\.index)), seedRatio: nil, downloaded: 0, uploaded: 0, wantedRunning: false, verified: PieceBitset(count: meta.pieceHashes.count))
        record.volumeUUID = try XCTUnwrap(destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        record.ownedSignatures = owned
        return record
    }

    private func restoredDeletionEngine(state: URL, records: [EngineRecord]) async throws -> TorrentEngine {
        let writer = TorrentEngine(stateDirectory: state)
        try await writer.persistence.save(EngineArchive(cleanShutdown: false, settings: EngineSettings(), records: records))
        try await writer.persistence.close()
        let restored = TorrentEngine(stateDirectory: state)
        try await restored.prepareForActivation()
        try await restored.activatePreparedProfile()
        return restored
    }

    private func deletionSignature(destination: URL, name: String) async throws -> DiskSignature {
        let signature = try await TorrentDisk.currentSignature(destination: destination, path: name.split(separator: "/").map(String.init))
        return try XCTUnwrap(signature)
    }

    private func staleDeletionDevice(_ signature: DiskSignature) throws -> DiskSignature {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(signature)) as? [String: Any])
        object["device"] = signature.device ^ 0x0100_0000
        return try JSONDecoder().decode(DiskSignature.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testQuarantinedRestoredTorrentDeletesOwnedFileAfterDeviceRenumbering() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 42, count: 32_768), meta = fixture(Data(repeating: 42, count: 32_768))
        let file = root.appendingPathComponent(meta.name)
        try payload.write(to: file)
        let current = try await deletionSignature(destination: root, name: meta.name)
        let stale = try staleDeletionDevice(current)
        XCTAssertNotEqual(stale.device, current.device)
        var record = try deletionRecord(meta, destination: root, owned: [stale])
        record.quarantineError = "Previous ownership validation failed"
        let state = root.appendingPathComponent("state")
        let restored = try await restoredDeletionEngine(state: state, records: [record])
        let before = await restored.currentSnapshots()
        XCTAssertEqual(before.first?.state, .failed)
        let diskOpened = await restored.hasOpenPayloadForProfileTest(meta.id)
        XCTAssertFalse(diskOpened)

        try await restored.remove(meta.id, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let after = await restored.currentSnapshots()
        XCTAssertTrue(after.isEmpty)
        try await restored.shutdownForProfileSwitch()
        let relaunched = TorrentEngine(stateDirectory: state)
        try await relaunched.prepareForActivation()
        try await relaunched.activatePreparedProfile()
        let persisted = await relaunched.currentSnapshots()
        XCTAssertTrue(persisted.isEmpty)
        try await relaunched.shutdownForProfileSwitch()
    }

    func testDeletingMissingOwnedPayloadRemovesSidecarsAndPreservesOtherTorrent() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data(repeating: 1, count: 8))
        let missing = root.appendingPathComponent(meta.name)
        let sidecarName = ".torrenza-old-selection.parts"
        let sidecar = root.appendingPathComponent(sidecarName)
        try Data(repeating: 1, count: 8).write(to: missing)
        try Data([2, 3]).write(to: sidecar)
        let owned = try await [deletionSignature(destination: root, name: meta.name), deletionSignature(destination: root, name: sidecarName)]
        let record = try deletionRecord(meta, destination: root, owned: owned)
        try FileManager.default.removeItem(at: missing)
        let otherData = Data([4, 5, 6]), otherMeta = fixture(Data([4, 5, 6]), name: "other.bin")
        let otherFile = root.appendingPathComponent(otherMeta.name)
        try otherData.write(to: otherFile)
        let otherSignature = try await deletionSignature(destination: root, name: otherMeta.name)
        let otherRecord = try deletionRecord(otherMeta, destination: root, owned: [otherSignature])
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let restored = try await restoredDeletionEngine(state: root.appendingPathComponent("state"), records: [record, otherRecord])

        try await restored.remove(meta.id, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: otherFile), otherData)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.id), [otherMeta.id])
        XCTAssertEqual(snapshots.first?.state, .paused)
        try await restored.shutdownForProfileSwitch()
    }

    func testReplacementInodeAbortsDeletionBeforeAnyPayloadAndRetainsRecord() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8]), base = fixture(Data([1, 2, 3, 4, 5, 6, 7, 8]), name: "bundle")
        let meta = TorrentMetainfo(infoHash: base.infoHash, rawInfo: base.rawInfo, name: base.name, pieceLength: base.pieceLength, pieceHashes: base.pieceHashes, files: [
            TorrentFile(index: 0, path: ["a-owned"], length: 4, offset: 0),
            TorrentFile(index: 1, path: ["z-replaced"], length: 4, offset: 4)
        ], trackerTiers: [], isPrivate: true, isMultiFile: true)
        let first = root.appendingPathComponent("a-owned"), second = root.appendingPathComponent("z-replaced")
        try bytes.prefix(4).write(to: first)
        try bytes.suffix(4).write(to: second)
        let owned = try await [deletionSignature(destination: root, name: "a-owned"), deletionSignature(destination: root, name: "z-replaced")]
        let record = try deletionRecord(meta, destination: root, owned: owned)
        try FileManager.default.moveItem(at: second, to: root.appendingPathComponent("original-preserved"))
        try Data([9, 9, 9, 9]).write(to: second)
        let replacement = try await deletionSignature(destination: root, name: "z-replaced")
        XCTAssertNotEqual(replacement.inode, owned[1].inode)
        let state = root.appendingPathComponent("state")
        let restored = try await restoredDeletionEngine(state: state, records: [record])

        do { try await restored.remove(meta.id, deleteFiles: true); XCTFail("A replacement must prevent deletion") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: first), Data(bytes.prefix(4)))
        XCTAssertEqual(try Data(contentsOf: second), Data([9, 9, 9, 9]))
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.id), [meta.id])
        XCTAssertEqual(snapshots.first?.state, .failed)
        try await restored.shutdownForProfileSwitch()
        let relaunched = TorrentEngine(stateDirectory: state)
        try await relaunched.prepareForActivation()
        try await relaunched.activatePreparedProfile()
        let persisted = await relaunched.currentSnapshots()
        XCTAssertEqual(persisted.map(\.id), [meta.id])
        XCTAssertEqual(persisted.first?.state, .failed)
        try await relaunched.shutdownForProfileSwitch()
    }

    func testWrongVolumeUUIDRefusesDeletionAndPreservesPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3]), meta = fixture(Data([1, 2, 3]))
        let file = root.appendingPathComponent(meta.name)
        try payload.write(to: file)
        let signature = try await deletionSignature(destination: root, name: meta.name)
        var record = try deletionRecord(meta, destination: root, owned: [signature])
        record.volumeUUID = UUID().uuidString
        let restored = try await restoredDeletionEngine(state: root.appendingPathComponent("state"), records: [record])

        do { try await restored.remove(meta.id, deleteFiles: true); XCTFail("A different volume must prevent deletion") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: file), payload)
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.id), [meta.id])
        XCTAssertEqual(snapshots.first?.state, .failed)
        try await restored.shutdownForProfileSwitch()
    }

    func testLegacyDiskSignaturesDeleteSidecarWithoutReopeningMissingPayload() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = fixture(Data([1, 2, 3]))
        let payload = root.appendingPathComponent(meta.name)
        let sidecarName = ".torrenza-legacy.parts", sidecar = root.appendingPathComponent(".torrenza-legacy.parts")
        try Data([1, 2, 3]).write(to: payload)
        try Data([4, 5]).write(to: sidecar)
        let signatures = try await [deletionSignature(destination: root, name: meta.name), deletionSignature(destination: root, name: sidecarName)]
        var record = try deletionRecord(meta, destination: root, owned: nil)
        record.diskSignatures = signatures
        try FileManager.default.removeItem(at: payload)
        let restored = try await restoredDeletionEngine(state: root.appendingPathComponent("state"), records: [record])

        try await restored.remove(meta.id, deleteFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let snapshots = await restored.currentSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
        try await restored.shutdownForProfileSwitch()
    }

    func testRemovalExcludesMutationsWhileWaitingForVerificationWorker() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3]), meta = fixture(Data([1, 2, 3]))
        let file = root.appendingPathComponent(meta.name)
        try payload.write(to: file)
        let signature = try await deletionSignature(destination: root, name: meta.name)
        let record = try deletionRecord(meta, destination: root, owned: [signature])
        let restored = try await restoredDeletionEngine(state: root.appendingPathComponent("state"), records: [record])
        let gate = DeletionVerificationGate()
        await restored.installHeldDeletionVerification(meta.id, gate: gate)
        await gate.waitUntilEntered()
        let removal = Task { try await restored.remove(meta.id, deleteFiles: true) }
        // stopSession cancels its worker, then awaits its completion. The held
        // continuation makes this interval deterministic, without polling/sleeps.
        await gate.waitUntilCancelled()
        let before = await restored.deletionMutationState(meta.id)

        await restored.start(meta.id)
        await restored.recheck(meta.id)
        do {
            try await restored.setSelectedFiles(meta.id, selectedFiles: [])
            XCTFail("Selection changes must be excluded during removal")
        } catch { }
        await restored.schedule()
        let during = await restored.deletionMutationState(meta.id)
        XCTAssertEqual(during?.generation, before?.generation)
        XCTAssertEqual(during?.selectedFiles, [0])
        XCTAssertEqual(during?.wantedRunning, false)
        XCTAssertEqual(during?.diskOpen, false)
        XCTAssertEqual(during?.reserved, true)
        XCTAssertEqual(during?.busy, true)
        let snapshots = await restored.currentSnapshots()
        XCTAssertEqual(snapshots.first?.state, .paused)

        await gate.release()
        try await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let after = await restored.currentSnapshots()
        XCTAssertTrue(after.isEmpty)
        try await restored.shutdownForProfileSwitch()
    }
}

private actor DeletionVerificationGate {
    private var worker: CheckedContinuation<Void, Never>?
    private var entered = false
    private var cancelled = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        await withCheckedContinuation { continuation in
            worker = continuation
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func cancellationObserved() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilCancelled() async {
        if !cancelled { await withCheckedContinuation { cancellationWaiters.append($0) } }
    }

    func release() {
        worker?.resume()
        worker = nil
    }
}

private extension TorrentEngine {
    func installHeldDeletionVerification(_ id: String, gate: DeletionVerificationGate) {
        sessions[id]?.verificationTask = Task {
            await withTaskCancellationHandler {
                await gate.hold()
            } onCancel: {
                Task { await gate.cancellationObserved() }
            }
        }
    }

    func deletionMutationState(_ id: String) -> (generation: Int, selectedFiles: Set<Int>, wantedRunning: Bool, diskOpen: Bool, reserved: Bool, busy: Bool)? {
        guard let session = sessions[id] else { return nil }
        return (session.generation, session.record.selectedFiles, session.record.wantedRunning, session.disk != nil, refreshingIDs.contains(id), session.busy)
    }
}
