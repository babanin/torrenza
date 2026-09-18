import Foundation
import Darwin
import TorrentCore

/// Serializes checkpoint I/O on a dedicated queue. The caller owns schema/version validation.
public actor DurableJSONStore<Value: Codable & Sendable> {
    private let directory: URL
    private let filename: String
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "app.torrenza.checkpoint", qos: .utility)

    public init(directory: URL, filename: String = "transfers.json", maximumBytes: Int = 128 * 1_024 * 1_024) {
        precondition(!filename.isEmpty && !filename.contains("/") && filename != "." && filename != ".." && !filename.contains("\0"))
        precondition(maximumBytes > 0)
        self.directory = directory; self.filename = filename; self.maximumBytes = maximumBytes
    }

    public func load() async throws -> Value? {
        let directory = directory, filename = filename, maximumBytes = maximumBytes
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if root < 0 && errno == ENOENT { return nil }
                    guard root >= 0 else { throw Self.failure("Open checkpoint directory") }; defer { Darwin.close(root) }
                    let fd = openat(root, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    if fd < 0 && errno == ENOENT { return nil }
                    guard fd >= 0 else { throw Self.failure("Open checkpoint") }; defer { Darwin.close(fd) }
                    var info = stat()
                    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumBytes else { throw TorrentError.storage("Invalid or oversized checkpoint") }
                    var data = Data(count: Int(info.st_size))
                    try data.withUnsafeMutableBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let count = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw Self.failure("Read checkpoint") }; offset += count
                        }
                    }
                    return try JSONDecoder().decode(Value.self, from: data)
                })
            }
        }
    }

    public func save(_ value: Value) async throws {
        let directory = directory, filename = filename, maximumBytes = maximumBytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result {
                    let data = try JSONEncoder().encode(value)
                    guard data.count <= maximumBytes else { throw TorrentError.storage("Checkpoint exceeds size limit") }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard root >= 0 else { throw Self.failure("Open checkpoint directory") }; defer { Darwin.close(root) }
                    let temporary = ".\(filename).\(UUID().uuidString).tmp"
                    let fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw Self.failure("Create checkpoint") }
                    defer { Darwin.close(fd); unlinkat(root, temporary, 0) }
                    try data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw Self.failure("Write checkpoint") }; offset += count
                        }
                    }
                    guard fsync(fd) == 0 else { throw Self.failure("Flush checkpoint") }
                    // Ask macOS to flush the device cache where the filesystem supports it.
                    if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw Self.failure("Commit checkpoint") }
                    guard renameat(root, temporary, root, filename) == 0 else { throw Self.failure("Replace checkpoint") }
                    guard fsync(root) == 0 else { throw Self.failure("Commit checkpoint directory") }
                })
            }
        }
    }

    private static func failure(_ action: String) -> TorrentError { .storage("\(action): \(String(cString: strerror(errno)))") }
}
