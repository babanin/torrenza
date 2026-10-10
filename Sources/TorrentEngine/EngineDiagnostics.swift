import Foundation

/// Lightweight development telemetry. Payload reservations are not total process memory.
public struct EngineDiagnostics: Codable, Sendable {
    public let establishedPeers: Int
    public let admittedConnections: Int
    public let outstandingRequests: Int
    public let budgetUsed: Int
    public let budgetHighWaterMark: Int
    public let budgetLimit: Int
}

extension TorrentEngine {
    public func diagnostics() async -> EngineDiagnostics {
        let peers = sessions.values.flatMap { $0.peers.values }
        let established = peers.count
        let admitted = totalPeers
        let outstanding = peers.reduce(0) { $0 + $1.pending.count }
        return await EngineDiagnostics(establishedPeers: established, admittedConnections: admitted,
                                       outstandingRequests: outstanding, budgetUsed: budget.used,
                                       budgetHighWaterMark: budget.highWaterMark, budgetLimit: budget.limit)
    }
}
