import Foundation
import TorrentCore
import TorrentStorage

/// The refreshed file list no longer contains any previously selected file.
/// The caller can present that list and retry with an explicit selection.
public struct TorrentRefreshSelectionRequired: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "None of the previously selected files remain in this torrent. Choose the files to download before refreshing." }
}

extension TorrentEngine {
    public func refreshSource(for id: String) -> TorrentRefreshSource? {
        guard let record = sessions[id]?.record else { return nil }
        return record.refreshSource ?? record.metainfo.refreshSource
    }

    public func setRefreshSource(_ source: TorrentRefreshSource, for id: String) async throws {
        guard !shuttingDown else { throw CancellationError() }
        guard let session = sessions[id] else { throw TorrentError.storage("This torrent is no longer in your library") }
        guard refreshingIDs.isEmpty else { throw TorrentError.storage("Wait for the current torrent refresh to finish") }
        guard sessionOperationCounts[id] == nil else { throw TorrentError.storage("Wait for this torrent's current operation to finish") }
        refreshingIDs.insert(id)
        defer { finishRefresh([id]) }
        await acquireSaveGate()
        defer { releaseSaveGate() }
        try Task.checkCancellation()
        guard !shuttingDown, sessions[id] === session else { throw CancellationError() }
        var record = session.record
        record.refreshSource = source
        try await persistence.replaceTransfer(id, with: record)
        session.record.refreshSource = source
        session.snapshot.refreshSource = source
        updateActivity()
    }

    /// Replaces one swarm while retaining its destination, selection, history,
    /// and owned files. Only unchanged verified byte ranges are trusted again.
    public func refresh(id: String, metainfo: TorrentMetainfo, selectedFiles: Set<Int>? = nil) async throws -> String {
        guard !shuttingDown else { throw CancellationError() }
        guard libraryError == nil else { throw TorrentError.storage("Saved transfers could not be read") }
        guard refreshingIDs.isEmpty else { throw TorrentError.storage("Wait for the current torrent refresh to finish") }
        guard let original = sessions[id] else { throw TorrentError.storage("This torrent is no longer in your library") }
        try Self.validateMetainfo(metainfo)
        if let selectedFiles {
            let validFiles = Set(metainfo.files.filter { !$0.isPadding }.map(\.index))
            guard selectedFiles.isSubset(of: validFiles) else { throw TorrentError.storage("Invalid refreshed file selection") }
        }
        guard !original.busy, sessionOperationCounts[id] == nil else { throw TorrentError.storage("Wait for this torrent's current operation to finish") }
        // Fetching an unchanged hash must not open or scan payload files.
        if metainfo.id == id { return id }
        guard sessions[metainfo.id] == nil else { throw TorrentError.storage("The refreshed torrent is already in your library") }
        guard metainfo.isMultiFile == original.record.metainfo.isMultiFile,
              metainfo.name == original.record.metainfo.name else {
            throw TorrentError.storage("The refreshed torrent uses a different content folder or file name. Add it separately to choose its destination.")
        }
        let reserved: Set<String> = [id, metainfo.id]
        refreshingIDs.formUnion(reserved)
        defer { finishRefresh(reserved) }
        let priorState = original.snapshot.state
        let priorError = original.snapshot.error
        original.busy = true
        defer { original.busy = false }
        var candidate: EngineSession?
        var committed = false
        do {
            await stopSession(id, state: .checking)
            let generation = original.generation
            try validateRefresh(original, id: id, generation: generation)
            // An existing disk provides up-to-date ownership even after partial
            // downloads; restored sessions validate only their managed files.
            if original.disk != nil { try await updateOwnership(original) }
            try validateRefresh(original, id: id, generation: generation)
            let old = original.record
            let oldFiles = Dictionary(uniqueKeysWithValues: old.metainfo.files.filter { !$0.isPadding }.map { ($0.path.joined(separator: "/"), $0) })
            let owned = old.ownedSignatures ?? []
            let ownedPaths = Set(owned.map(\.path))
            var selected: Set<Int> = []
            for file in metainfo.files where !file.isPadding {
                let path = file.path.joined(separator: "/")
                if let previous = oldFiles[path] {
                    guard file.length == previous.length else {
                        throw TorrentError.storage("The refreshed torrent changes the size of an existing file: \(path). Add it separately to preserve the original data.")
                    }
                    if old.selectedFiles.contains(previous.index) { selected.insert(file.index) }
                } else { selected.insert(file.index) }
            }
            if let selectedFiles { selected = selectedFiles }
            if !old.selectedFiles.isEmpty && selected.isEmpty { throw TorrentRefreshSelectionRequired() }
            let originalSelectedPaths = Set(old.metainfo.files.filter { old.selectedFiles.contains($0.index) && !$0.isPadding }.map { $0.path.joined(separator: "/") })
            let selectedOwnedPaths = Set(metainfo.files.filter { selected.contains($0.index) && !$0.isPadding }.map { $0.path.joined(separator: "/") }).intersection(ownedPaths)
            let requiredPaths = originalSelectedPaths.union(selectedOwnedPaths)
            guard requiredPaths.isSubset(of: ownedPaths) else { throw TorrentError.storage("The original torrent's file ownership is missing") }
            if !requiredPaths.isEmpty {
                try await TorrentDisk.validateOwnedFiles(destination: old.destination, signatures: owned.filter { requiredPaths.contains($0.path) }, allowMissing: false)
            }
            try validateRefresh(original, id: id, generation: generation)
            if let expected = old.volumeUUID {
                guard try old.destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == expected else {
                    throw TorrentError.storage("The original destination volume is unavailable")
                }
            }
            let requestedPaths = Set(metainfo.files.filter { selected.contains($0.index) }.map { $0.path.reduce(old.destination) { $0.appendingPathComponent($1) }.standardizedFileURL.path })
            for (otherID, other) in sessions where otherID != id {
                let otherPaths = Set((other.record.ownedSignatures ?? []).map { other.record.destination.appendingPathComponent($0.path).standardizedFileURL.path })
                guard requestedPaths.isDisjoint(with: otherPaths) else { throw TorrentError.storage("Another managed torrent already owns one of these destination files") }
            }
            var record = old
            record.metainfo = metainfo
            record.refreshSource = old.refreshSource ?? old.metainfo.refreshSource ?? metainfo.refreshSource
            record.selectedFiles = selected
            record.wantedRunning = !selected.isEmpty && old.quarantineError == nil && (old.wantedRunning || priorState == .completed)
            record.verified = PieceBitset(count: metainfo.pieceHashes.count)
            record.diskSignatures = nil
            record.fileUploadedBytes = [:]
            for file in metainfo.files where !file.isPadding {
                if let previous = oldFiles[file.path.joined(separator: "/")] {
                    record.fileUploadedBytes?[file.index] = old.fileUploadedBytes?[previous.index] ?? 0
                }
            }
            let retainedPaths = Set(metainfo.files.filter { !$0.isPadding }.map { $0.path.joined(separator: "/") })
            if oldFiles.contains(where: { path, file in !retainedPaths.contains(path) && (old.fileUploadedBytes?[file.index] ?? 0) > 0 }) {
                // Aggregate history still includes removed files, whose upload
                // counters can no longer be attributed in the current file list.
                record.fileUploadHistoryComplete = false
            }
            let next = EngineSession(record: record)
            candidate = next
            next.snapshot.state = .checking
            if !selected.isEmpty {
                let disk = try TorrentDisk(metainfo: metainfo, destination: old.destination, selectedFiles: selected, allowExisting: true, allowedExistingSignatures: owned)
                next.disk = disk
                try await disk.prepare()
                let signatures = try await disk.signatures()
                try validateRefresh(original, id: id, generation: generation)
                try await updateOwnership(next)
                next.record.diskSignatures = signatures
                let plan = Self.refreshPiecePlan(old: old, new: next.record)
                next.record.verified = plan.verified
                for index in plan.check {
                    try validateRefresh(original, id: id, generation: generation)
                    try await budget.acquire(65_536)
                    do {
                        let valid = try await disk.verifyPiece(index)
                        await budget.release(65_536)
                        next.record.verified[index] = valid
                    } catch { await budget.release(65_536); throw error }
                }
                try await disk.flush()
            }
            await refreshProgress(next)
            try validateRefresh(original, id: id, generation: generation)
            next.snapshot.state = next.record.quarantineError != nil ? .failed : (next.record.wantedRunning ? .queued : .paused)
            await acquireSaveGate()
            do {
                try validateRefresh(original, id: id, generation: generation)
                try await persistence.replaceTransfer(id, with: next.record)
                // No suspension between successful persistence and the visible
                // identity swap. A concurrent checkpoint sees exactly one record.
                next.securityScoped = original.securityScoped
                original.securityScoped = false
                sessions.removeValue(forKey: id)
                sessions[metainfo.id] = next
                committed = true
                releaseSaveGate()
            } catch { releaseSaveGate(); throw error }
            await original.disk?.close()
            original.disk = nil
            next.busy = false
            await schedule()
            updateActivity()
            return metainfo.id
        } catch {
            if !committed {
                // Delete only newly created identities. Never unlink reused or
                // concurrently replaced files while restoring the old transfer.
                await candidate?.disk?.rollbackPreparation()
                if sessions[id] === original {
                    let restoredState: TransferState = [.downloading, .seeding, .queued].contains(priorState) ? .queued : priorState
                    original.snapshot.state = original.record.quarantineError != nil ? .failed : (shuttingDown ? .paused : restoredState)
                    original.snapshot.error = original.record.quarantineError ?? priorError
                }
                original.busy = false
                if !shuttingDown { await schedule(); updateActivity() }
            }
            throw error
        }
    }

    private func validateRefresh(_ session: EngineSession, id: String, generation: Int) throws {
        try Task.checkCancellation()
        guard !shuttingDown, sessions[id] === session, session.generation == generation else { throw CancellationError() }
    }

    func finishRefresh(_ ids: Set<String>) {
        refreshingIDs.subtract(ids)
        if refreshingIDs.isEmpty {
            let waiters = refreshWaiters; refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func finishSessionOperation(_ id: String) {
        guard let count = sessionOperationCounts[id] else { return }
        if count == 1 { sessionOperationCounts.removeValue(forKey: id) }
        else { sessionOperationCounts[id] = count - 1 }
    }

    func acquireSaveGate() async {
        if saveGateHeld { await withCheckedContinuation { saveGateWaiters.append($0) } }
        else { saveGateHeld = true }
    }

    func releaseSaveGate() {
        if saveGateWaiters.isEmpty { saveGateHeld = false }
        else { saveGateWaiters.removeFirst().resume() }
    }
}

extension TorrentEngine {
    struct RefreshSegment: Equatable {
        let path: String?
        let offset: Int64
        let length: Int64
    }

    /// Segments are compared by physical file bytes, rather than torrent-wide
    /// offsets or file indices, which can change when an episode is inserted.
    nonisolated static func refreshPiecePlan(old: EngineRecord, new: EngineRecord) -> (verified: PieceBitset, check: [Int]) {
        var verified = PieceBitset(count: new.metainfo.pieceHashes.count)
        var check: [Int] = []
        let wanted = EngineSession.wantedPieces(new)
        let oldFiles = Dictionary(uniqueKeysWithValues: old.metainfo.files.filter { !$0.isPadding }.map { ($0.path.joined(separator: "/"), $0) })
        let existing = Set((old.ownedSignatures ?? []).map(\.path))
        func segments(_ record: EngineRecord, piece: Int) -> [RefreshSegment]? {
            let start = Int64(piece) * Int64(record.metainfo.pieceLength)
            let end = start + Int64(record.metainfo.lengthOfPiece(piece))
            let files = record.metainfo.files
            var low = 0, high = files.count
            while low < high {
                let middle = low + (high - low) / 2
                if files[middle].offset + files[middle].length <= start { low = middle + 1 }
                else { high = middle }
            }
            var result: [RefreshSegment] = []
            while low < files.count, files[low].offset < end {
                let file = files[low]
                let a = max(start, file.offset), b = min(end, file.offset + file.length)
                if b > a {
                    if file.isPadding { result.append(RefreshSegment(path: nil, offset: 0, length: b - a)) }
                    else {
                        guard record.selectedFiles.contains(file.index) else { return nil }
                        result.append(RefreshSegment(path: file.path.joined(separator: "/"), offset: a - file.offset, length: b - a))
                    }
                }
                low += 1
            }
            return result
        }
        for index in 0..<verified.count where wanted[index] {
            guard let ranges = segments(new, piece: index), ranges.allSatisfy({ $0.path == nil || existing.contains($0.path!) }) else { continue }
            var prefix: Int64 = 0
            var oldIndex: Int?
            for range in ranges {
                if let path = range.path, let file = oldFiles[path] {
                    let start = file.offset + range.offset - prefix
                    if start >= 0, start % Int64(old.metainfo.pieceLength) == 0 { oldIndex = Int(start / Int64(old.metainfo.pieceLength)) }
                    break
                }
                prefix += range.length
            }
            if let previous = oldIndex, old.verified.count > previous, old.verified[previous],
               old.metainfo.lengthOfPiece(previous) == new.metainfo.lengthOfPiece(index),
               old.metainfo.pieceHashes[previous] == new.metainfo.pieceHashes[index],
               segments(old, piece: previous) == ranges {
                verified[index] = true
            } else { check.append(index) }
        }
        return (verified, check)
    }
}
