import Foundation

public enum ResourceBudgetError: Error, Equatable, Sendable {
    case invalidReservation
    case exceedsLimit
}

/// A FIFO, cancellation-safe shared byte budget. Release every successful acquisition
/// after its payload is no longer retained, including failure and cancellation paths.
public actor ResourceBudget {
    public let limit: Int
    public private(set) var used = 0
    public private(set) var highWaterMark = 0
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []
    var pendingCount: Int { waiters.count }

    public init(limit: Int) {
        precondition(limit >= 0)
        self.limit = limit
    }

    public func acquire(_ bytes: Int) async throws {
        try Task.checkCancellation()
        guard bytes >= 0 else { throw ResourceBudgetError.invalidReservation }
        guard bytes <= limit else { throw ResourceBudgetError.exceedsLimit }
        if bytes == 0 { return }
        if waiters.isEmpty && bytes <= limit - used {
            reserve(bytes)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, bytes: bytes, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Cancellation can race with a release that grants this request. Return its
        // reservation before throwing if it was already removed from the wait queue.
        if Task.isCancelled {
            release(bytes)
            throw CancellationError()
        }
    }

    /// Nonblocking admission for request pumps that must keep receiving in order
    /// to release existing reservations. Never bypasses queued FIFO waiters.
    public func tryAcquire(_ bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= limit, !Task.isCancelled else { return false }
        if bytes == 0 { return true }
        guard waiters.isEmpty, bytes <= limit - used else { return false }
        reserve(bytes)
        return true
    }

    public func release(_ bytes: Int) {
        precondition(bytes >= 0 && bytes <= used, "Unbalanced payload budget release")
        used -= bytes
        drain()
    }

    private func reserve(_ bytes: Int) {
        used += bytes
        highWaterMark = max(highWaterMark, used)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }

    private func drain() {
        while let first = waiters.first, first.bytes <= limit - used {
            waiters.removeFirst()
            reserve(first.bytes)
            first.continuation.resume()
        }
    }
}
