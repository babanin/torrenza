import Testing
@testable import TorrentCore

struct BudgetTests {
    @Test func liveIncreaseAdmitsQueuedReservation() async throws {
        let budget = ResourceBudget(limit: 32)
        try await budget.acquire(32)
        let queued = Task { try await budget.acquire(16) }
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        #expect(await budget.pendingCount == 1)
        await budget.resize(limit: 64)
        try await queued.value
        #expect(await budget.used == 48)
        await budget.release(48)
        #expect(await budget.used == 0)
    }

    @Test func liveDecreaseRetainsReservationsAndSuspendsAdmission() async throws {
        let budget = ResourceBudget(limit: 64)
        try await budget.acquire(64)
        await budget.resize(limit: 32)
        #expect(await budget.used == 64)
        #expect(!(await budget.tryAcquire(1)))
        let queued = Task { try await budget.acquire(1) }
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        await budget.release(32)
        #expect(await budget.pendingCount == 1)
        await budget.release(1)
        try await queued.value
        #expect(await budget.used == 32)
        #expect(await budget.highWaterMark == 64)
        await budget.release(32)
    }

    @Test func shrinkRejectsImpossibleQueuedRequestWithoutLeaking() async throws {
        let budget = ResourceBudget(limit: 64)
        try await budget.acquire(64)
        let queued = Task { try await budget.acquire(48) }
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        await budget.resize(limit: 32)
        await #expect(throws: ResourceBudgetError.exceedsLimit) { try await queued.value }
        #expect(await budget.pendingCount == 0)
        #expect(await budget.used == 64)
        await budget.release(64)
        #expect(await budget.used == 0)
    }

    @Test func verificationHeadroomBypassesStalledPayloadWaiters() async throws {
        let budget = ResourceBudget(limit: 64, verificationHeadroom: 16)
        #expect(await budget.tryAcquire(48))
        #expect(!(await budget.tryAcquire(1)))
        let payload = Task { try await budget.acquire(1) }
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        try await budget.acquire(16, purpose: .verification)
        #expect(await budget.used == 64)
        #expect(await budget.pendingCount == 1)
        await budget.release(16)
        #expect(await budget.pendingCount == 1)
        payload.cancel()
        await #expect(throws: CancellationError.self) { try await payload.value }
        await budget.release(48)
        #expect(await budget.used == 0)
    }

    @Test func rejectsOversizedAndInvalidReservations() async throws {
        let budget = ResourceBudget(limit: 16)
        await #expect(throws: ResourceBudgetError.exceedsLimit) { try await budget.acquire(17) }
        await #expect(throws: ResourceBudgetError.invalidReservation) { try await budget.acquire(-1) }
        try await budget.acquire(0)
        try await budget.acquire(16)
        #expect(await budget.used == 16)
        await budget.release(16)
        #expect(await budget.used == 0)
        #expect(await budget.highWaterMark == 16)
    }

    @Test func cancellationDoesNotLeakAndUnblocksQueue() async throws {
        let budget = ResourceBudget(limit: 16)
        try await budget.acquire(16)
        let cancelled = Task { try await budget.acquire(16) }
        // Wait for enqueue using bounded scheduler yields rather than timing sleeps.
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        #expect(await budget.pendingCount == 1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await budget.used == 16)
        #expect(await budget.pendingCount == 0)
        await budget.release(16)
        try await budget.acquire(16)
        await budget.release(16)
        #expect(await budget.used == 0)
    }

    @Test func nonblockingAdmissionPreservesFIFO() async throws {
        let budget = ResourceBudget(limit: 16)
        #expect(await budget.tryAcquire(8))
        #expect(!(await budget.tryAcquire(-1)))
        #expect(!(await budget.tryAcquire(17)))
        let queued = Task { try await budget.acquire(16) }
        for _ in 0..<1000 {
            if await budget.pendingCount == 1 { break }
            await Task.yield()
        }
        #expect(await budget.pendingCount == 1)
        #expect(!(await budget.tryAcquire(1)))
        #expect(await budget.tryAcquire(0))
        await budget.release(8)
        try await queued.value
        #expect(await budget.used == 16)
        #expect(!(await budget.tryAcquire(1)))
        await budget.release(16)
        #expect(await budget.tryAcquire(16))
        await budget.release(16)
    }

    @Test func concurrentReservationsRemainBounded() async throws {
        let budget = ResourceBudget(limit: 64)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let amount = index % 16 + 1
                    try await budget.acquire(amount)
                    #expect(await budget.used <= 64)
                    await Task.yield()
                    await budget.release(amount)
                }
            }
            try await group.waitForAll()
        }
        #expect(await budget.used == 0)
        #expect(await budget.highWaterMark <= 64)
        #expect(await budget.highWaterMark > 0)
    }

    @Test func cancellationGrantRaceDoesNotLeak() async throws {
        for _ in 0..<100 {
            let budget = ResourceBudget(limit: 1)
            try await budget.acquire(1)
            let task = Task {
                do {
                    try await budget.acquire(1)
                    await budget.release(1)
                } catch is CancellationError {}
            }
            task.cancel()
            await budget.release(1)
            try await task.value
            #expect(await budget.used == 0)
        }
    }
}
