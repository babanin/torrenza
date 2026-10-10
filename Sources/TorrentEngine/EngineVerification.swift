import TorrentStorage

extension TorrentEngine {
    /// Download completion, Recheck, and refresh share the same global disk/hash
    /// concurrency ceiling and payload verification headroom.
    func verifyPiece(_ disk: TorrentDisk, index: Int) async throws -> Bool {
        try await verificationSlots.acquire(1)
        do {
            try await budget.acquire(65_536, purpose: .verification)
            do {
                let valid = try await disk.verifyPiece(index)
                await budget.release(65_536)
                await verificationSlots.release(1)
                return valid
            } catch {
                await budget.release(65_536)
                throw error
            }
        } catch {
            await verificationSlots.release(1)
            throw error
        }
    }
}
