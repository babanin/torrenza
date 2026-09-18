import Foundation
import Network
import TorrentCore

/// Every continuation has one completion path, including cancellation before registration.
private final class NetworkCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var finished = false
    private var timer: DispatchSourceTimer?
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result = pendingResult { pendingResult = nil; lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func scheduleTimeout(on queue: DispatchQueue, after timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self] in
            if self?.finish(.failure(TorrentError.network("Network operation timed out"))) == true { onTimeout() }
        }
        source.resume()
        lock.lock()
        if finished { lock.unlock(); source.cancel() }
        else { timer = source; lock.unlock() }
    }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        if continuation == nil { pendingResult = result }
        let timer = self.timer; self.timer = nil; lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result); return true
    }
}

/// A bounded TCP/UDP transport. One reader and one writer may operate concurrently.
public final class NetworkTransport: @unchecked Sendable {
    public let connection: NWConnection
    private let queue = DispatchQueue(label: "app.torrenza.network", qos: .utility)
    public init(connection: NWConnection) { self.connection = connection }
    public convenience init(endpoint: PeerEndpoint, udp: Bool = false) throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port), endpoint.port != 0 else { throw TorrentError.network("Invalid port") }
        self.init(connection: NWConnection(host: .init(endpoint.host), port: port, using: udp ? .udp : .tcp))
    }
    private func operation<Value: Sendable>(timeout: TimeInterval, cancelOnTimeout: Bool = true, _ start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw TorrentError.network("Invalid network timeout") }
        let completion = NetworkCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                completion.scheduleTimeout(on: queue, after: timeout) { [connection] in
                    if cancelOnTimeout { connection.cancel() }
                }
                start { result in completion.finish(result) }
            }
        } onCancel: { [connection] in
            completion.finish(.failure(CancellationError())); connection.cancel()
        }
    }
    public func start(timeout: TimeInterval = 15) async throws {
        let _: Bool = try await operation(timeout: timeout) { [connection, queue] finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; finish(.success(true))
                case .failed(let error): connection.stateUpdateHandler = nil; finish(.failure(error))
                case .cancelled: connection.stateUpdateHandler = nil; finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    public func send(_ data: Data, timeout: TimeInterval = 30) async throws {
        let _: Bool = try await operation(timeout: timeout) { [connection] finish in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(true)) }
            })
        }
    }
    public func receiveExactly(_ count: Int, timeout: TimeInterval = 120) async throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw TorrentError.network("Invalid network timeout") }
        guard count >= 0, count <= PeerMessage.maximumFrameLength else { throw TorrentError.invalidMessage("Receive exceeds frame limit") }
        var output = Data(); output.reserveCapacity(count)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while output.count < count {
            let remaining = count - output.count
            let remainingTime = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingTime > 0 else { connection.cancel(); throw TorrentError.network("Network receive timed out") }
            let part: Data = try await operation(timeout: remainingTime) { [connection] finish in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { finish(.failure(error)) }
                    else if let data, !data.isEmpty { finish(.success(data)) }
                    else { finish(.failure(TorrentError.network(complete ? "Peer closed connection" : "Empty network read"))) }
                }
            }
            output.append(part)
        }
        return output
    }
    public func receiveDatagram(timeout: TimeInterval = 15) async throws -> Data {
        try await operation(timeout: timeout) { [connection] finish in
            connection.receiveMessage { data, _, _, error in
                if let error { finish(.failure(error)) }
                else if let data, data.count <= 65_535 { finish(.success(data)) }
                else { finish(.failure(TorrentError.invalidMessage("Invalid UDP datagram"))) }
            }
        }
    }
    public func close() { connection.cancel() }
}
