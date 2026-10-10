import Foundation

public enum ResourceBudgetError: Error, Equatable, Sendable {
    case invalidReservation
    case exceedsLimit
}

/// A cancellation-safe shared byte budget, FIFO within each reservation purpose.
/// Verification can bypass payload waiters to use its protected headroom.
/// Release every successful acquisition
/// after its payload is no longer retained, including failure and cancellation paths.
public actor ResourceBudget {
    public enum ReservationPurpose: Sendable { case payload, verification }
    public private(set) var limit: Int
    public let verificationHeadroom: Int
    public private(set) var used = 0
    public private(set) var highWaterMark = 0
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let purpose: ReservationPurpose
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []
    var pendingCount: Int { waiters.count }

    public init(limit: Int, verificationHeadroom: Int = 0) {
        precondition(limit >= 0 && verificationHeadroom >= 0)
        self.limit = limit
        self.verificationHeadroom = verificationHeadroom
    }

    /// Resizing preserves existing reservations, including usage above the new limit.
    /// New admission waits until releases make room. Requests larger than the new
    /// ceiling fail rather than remaining queued indefinitely.
    public func resize(limit: Int) {
        precondition(limit >= 0)
        self.limit = limit
        let impossible = waiters.filter { $0.bytes > ceiling(for: $0.purpose) }
        waiters.removeAll { $0.bytes > ceiling(for: $0.purpose) }
        for waiter in impossible { waiter.continuation.resume(throwing: ResourceBudgetError.exceedsLimit) }
        drain()
    }

    public func acquire(_ bytes: Int, purpose: ReservationPurpose = .payload) async throws {
        try Task.checkCancellation()
        guard bytes >= 0 else { throw ResourceBudgetError.invalidReservation }
        guard bytes <= ceiling(for: purpose) else { throw ResourceBudgetError.exceedsLimit }
        if bytes == 0 { return }
        if !hasEarlierWaiter(for: purpose) && bytes <= ceiling(for: purpose) - used {
            reserve(bytes)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, bytes: bytes, purpose: purpose, continuation: continuation))
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
    /// to release existing reservations. Verification may bypass payload waiters.
    public func tryAcquire(_ bytes: Int, purpose: ReservationPurpose = .payload) -> Bool {
        guard bytes >= 0, bytes <= ceiling(for: purpose), !Task.isCancelled else { return false }
        if bytes == 0 { return true }
        guard !hasEarlierWaiter(for: purpose), bytes <= ceiling(for: purpose) - used else { return false }
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
        // Keep verification independent of stalled payload admission so a full
        // request pipeline cannot prevent completed pieces from being checked.
        while let index = nextAdmissibleWaiter() {
            let first = waiters.remove(at: index)
            reserve(first.bytes)
            first.continuation.resume()
        }
    }

    private func ceiling(for purpose: ReservationPurpose) -> Int {
        purpose == .verification ? limit : max(0, limit - verificationHeadroom)
    }

    private func hasEarlierWaiter(for purpose: ReservationPurpose) -> Bool {
        purpose == .payload ? !waiters.isEmpty : waiters.contains { $0.purpose == .verification }
    }

    private func nextAdmissibleWaiter() -> Int? {
        if let verification = waiters.firstIndex(where: { $0.purpose == .verification }), waiters[verification].bytes <= limit - used {
            return verification
        }
        guard let first = waiters.first, first.bytes <= ceiling(for: first.purpose) - used else { return nil }
        return 0
    }
}
