import Foundation
import TorrentCore
import TorrentStorage

extension TorrentEngine {
    var failedStorageIDs: Set<String> {
        Set(sessions.compactMap { id, session in
            session.record.quarantineError != nil && !session.record.selectedFiles.isEmpty ? id : nil
        })
    }

    /// Independent of the transfer ticker: an entirely failed library still
    /// recovers, without waking every half second or checkpointing unchanged data.
    func updateStorageRecovery() {
        if failedStorageIDs.isEmpty {
            storageRecoveryTask?.cancel()
            storageRecoveryTask = nil
            storageRecoveryTaskID = nil
            storageRecoveryCandidates.removeAll()
            return
        }
        guard storageRecoveryTask == nil, !shuttingDown, !activating,
              !storageRecoverySuspended, !failedStorageIDs.isEmpty else { return }
        let taskID = UUID()
        storageRecoveryTaskID = taskID
        storageRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Int.random(in: 30...90))) }
                catch { break }
                guard let self, await self.shouldCheckStorage() else { break }
                await self.recoverFailedStorage()
            }
            await self?.storageRecoveryFinished(taskID)
        }
    }

    private func shouldCheckStorage() -> Bool {
        !shuttingDown && !storageRecoverySuspended && !failedStorageIDs.isEmpty
    }

    private func storageRecoveryFinished(_ taskID: UUID) {
        guard storageRecoveryTaskID == taskID else { return }
        storageRecoveryTask = nil
        storageRecoveryTaskID = nil
    }

    /// Shuffle without replacement so a persistent failure cannot starve other
    /// disks. A successful sample triggers one paced pass over every other failure.
    func recoverFailedStorage(candidateIDs: [String]? = nil) async {
        guard !storageRecoveryInProgress, shouldCheckStorage(), !Task.isCancelled else { return }
        storageRecoveryInProgress = true
        defer { storageRecoveryInProgress = false; updateActivity() }
        let failed = failedStorageIDs
        storageRecoveryCandidates.removeAll { !failed.contains($0) }
        if storageRecoveryCandidates.isEmpty { storageRecoveryCandidates = failed.shuffled() }
        let ordered = candidateIDs ?? storageRecoveryCandidates
        guard let sample = ordered.first else { return }
        storageRecoveryCandidates.removeAll { $0 == sample }
        guard await recoverStorage(sample) else { return }
        let remaining = candidateIDs.map { Array($0.dropFirst()) } ?? failedStorageIDs.shuffled()
        for id in remaining {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
            guard shouldCheckStorage(), !Task.isCancelled else { break }
            _ = await recoverStorage(id)
        }
        storageRecoveryCandidates.removeAll()
        await schedule()
    }

    /// A cure means storage actually opened successfully, even for a torrent
    /// that would be queued by concurrency limits or stopped by its seed ratio.
    func recoverStorage(_ id: String) async -> Bool {
        guard !shuttingDown, !activating, !storageRecoverySuspended, !Task.isCancelled,
              libraryError == nil, !refreshingIDs.contains(id),
              sessionOperationCounts[id] == nil,
              let session = sessions[id], !session.busy,
              session.record.quarantineError != nil,
              !session.record.selectedFiles.isEmpty else { return false }
        sessionOperationCounts[id, default: 0] += 1
        defer { finishSessionOperation(id) }
        await acquireActionGate(id)
        defer { releaseActionGate(id) }
        guard !shuttingDown, !storageRecoverySuspended, !Task.isCancelled else { return false }
        do { return try await recoverStorageAction(id, session: session, automatic: true) }
        catch { return false }
    }

    /// Caller holds the per-torrent action gate. Manual Download retries use
    /// the same ownership checks without waiting for the background probe.
    func recoverStorageAction(_ id: String, session: EngineSession, automatic: Bool = false) async throws -> Bool {
        session.busy = true
        defer { session.busy = false }
        let generation = session.generation
        let record = session.record
        let disk = try TorrentDisk(metainfo: record.metainfo, destination: record.destination,
            selectedFiles: record.selectedFiles, allowExisting: true,
            requireExistingPayload: true, requireExistingSidecars: true)
        do {
            try await disk.prepareForRecovery(
                ownedSignatures: record.ownedSignatures ?? record.diskSignatures ?? [],
                expectedVolumeUUID: record.volumeUUID)
        } catch {
            await disk.close()
            throw error
        }
        await disk.close()
        await acquireSaveGate()
        defer { releaseSaveGate() }
        guard !shuttingDown, !(automatic && storageRecoverySuspended), !Task.isCancelled,
              sessions[id] === session, session.generation == generation,
              session.record.quarantineError != nil else { throw CancellationError() }
        var recovered = session.record
        // Older versions erased run intent when quarantining. The requested
        // automatic recovery includes those existing failures.
        recovered.wantedRunning = recovered.recoveryWantedRunning ?? true
        recovered.quarantineError = nil
        recovered.recoveryWantedRunning = nil
        try await persistence.saveQuarantine(recovered)
        session.record = recovered
        session.snapshot.error = nil
        session.snapshot.state = recovered.wantedRunning
            ? (session.selectedComplete && session.ratioReached ? .completed : .queued) : .paused
        publishSnapshots()
        return true
    }
}
