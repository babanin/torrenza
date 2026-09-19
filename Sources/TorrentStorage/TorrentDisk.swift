import Foundation
import CryptoKit
import Darwin
import TorrentCore

public struct DiskSignature: Codable, Sendable, Equatable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
}

/// All filesystem calls, including hashing, run on one utility queue, never a cooperative executor.
public actor TorrentDisk {
    private let worker: DiskWorker
    private let queue = DispatchQueue(label: "app.torrenza.disk", qos: .utility)
    public let metainfo: TorrentMetainfo
    public let selectedFiles: Set<Int>
    public let destination: URL

    public init(metainfo: TorrentMetainfo, destination: URL, selectedFiles: Set<Int>, allowExisting: Bool = false, requireExistingPayload: Bool = false, requireExistingSidecars: Bool = false) throws {
        try DiskWorker.validate(metainfo)
        guard !(requireExistingPayload || requireExistingSidecars) || allowExisting else { throw TorrentError.storage("Existing payload mode requires permission to reuse files") }
        guard selectedFiles.isSubset(of: Set(metainfo.files.filter { !$0.isPadding }.map(\.index))) else { throw TorrentError.storage("Invalid file selection") }
        self.metainfo = metainfo
        self.destination = destination
        self.selectedFiles = selectedFiles
        self.worker = DiskWorker(meta: metainfo, destination: destination, selected: selectedFiles, allowExisting: allowExisting, requireExistingPayload: requireExistingPayload, requireExistingSidecars: requireExistingSidecars)
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (DiskWorker) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = worker
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation(worker) }) }
        }
    }
    public func prepare() async throws { try await perform { try $0.prepare() } }
    public func write(offset: Int64, data: Data) async throws { try await perform { try $0.write(offset: offset, data: data) } }
    public func read(offset: Int64, length: Int) async throws -> Data { try await perform { try $0.read(offset: offset, length: length) } }
    public func verifyPiece(_ index: Int) async throws -> Bool { try await perform { try $0.verifyPiece(index) } }
    public func flush() async throws { try await perform { try $0.flush() } }
    public func signatures() async throws -> [DiskSignature] { try await perform { try $0.signatures() } }
    /// Deletes only files opened by this storage instance, after checking their identity.
    /// Parent directories and unrelated files are deliberately preserved.
    public func deleteFiles() async throws { try await perform { try $0.deleteFiles() } }
    public func removeFiles() async throws { try await deleteFiles() }
    public func close() async {
        let worker = worker
        await withCheckedContinuation { continuation in queue.async { worker.close(); continuation.resume() } }
    }

    public func fileSnapshots(verified: PieceBitset) -> [FileSnapshot] {
        Self.fileSnapshots(metainfo: metainfo, selectedFiles: selectedFiles, verified: verified)
    }

    /// Reconstructs progress from saved metadata without opening payload files.
    public nonisolated static func fileSnapshots(metainfo: TorrentMetainfo, selectedFiles: Set<Int>, verified: PieceBitset) -> [FileSnapshot] {
        // A word-level rank index makes this O(bitfield bytes + file count), rather
        // than walking every piece of every file whenever the UI requests progress.
        let words = (verified.bytes.count + 7) / 8
        var prefix = [Int64](repeating: 0, count: words + 1)
        verified.bytes.withUnsafeBytes { raw in
            for word in 0..<words {
                let start = word * 8, end = min(raw.count, start + 8)
                let count: Int
                if end - start == 8 { count = raw.loadUnaligned(fromByteOffset: start, as: UInt64.self).nonzeroBitCount }
                else { count = raw[start..<end].reduce(0) { $0 + $1.nonzeroBitCount } }
                prefix[word + 1] = prefix[word] + Int64(count)
            }
        }
        func rank(_ position: Int) -> Int64 {
            let position = min(position, verified.count), word = position / 64
            var result = prefix[word]
            for byte in (word * 8)..<(position / 8) { result += Int64(verified.bytes[byte].nonzeroBitCount) }
            if position % 8 != 0 { result += Int64((verified.bytes[position / 8] & (UInt8.max << (8 - position % 8))).nonzeroBitCount) }
            return result
        }
        let pieceLength = Int64(metainfo.pieceLength)
        func verifiedBefore(_ position: Int64) -> Int64 {
            let piece = Int(position / pieceLength)
            return rank(piece) * pieceLength + (piece < verified.count && verified[piece] ? position % pieceLength : 0)
        }
        return metainfo.files.filter { !$0.isPadding }.map { file in
            let bytes = verifiedBefore(file.offset + file.length) - verifiedBefore(file.offset)
            return FileSnapshot(file: file, selected: selectedFiles.contains(file.index), verifiedBytes: bytes)
        }
    }
}

private final class DiskWorker: @unchecked Sendable {
    struct Segment { let range: Range<Int64>; let path: [String]?; let fileOffset: Int64 }
    let meta: TorrentMetainfo
    let destination: URL
    let selected: Set<Int>
    let allowExisting: Bool
    let requireExistingSidecars: Bool
    let requireExistingPayload: Bool
    let totalLength: Int64
    var rootFD: Int32 = -1
    var rootIdentity: (UInt64, UInt64)?
    var segments: [Segment] = []
    var fileLengths: [String: Int64] = [:]
    var identities: [String: (UInt64, UInt64)] = [:]
    var cache: [String: Int32] = [:]
    var cacheOrder: [String] = []
    var prepared = false
    var dirty = Set<String>()
    var dirtyDirectories = Set<String>()
    static let maxOperation = 1_048_576

    init(meta: TorrentMetainfo, destination: URL, selected: Set<Int>, allowExisting: Bool, requireExistingPayload: Bool, requireExistingSidecars: Bool) {
        self.meta = meta; self.destination = destination; self.selected = selected; self.allowExisting = allowExisting; self.requireExistingPayload = requireExistingPayload; self.requireExistingSidecars = requireExistingSidecars
        self.totalLength = meta.totalLength
    }
    deinit { close() }
    static func validate(_ meta: TorrentMetainfo) throws {
        guard meta.pieceLength > 0, !meta.files.isEmpty else { throw TorrentError.storage("Invalid torrent layout") }
        var names = Set<String>(); var indexes = Set<Int>(); var total: Int64 = 0
        for file in meta.files {
            guard file.offset == total, file.length >= 0, !file.path.isEmpty,
                  indexes.insert(file.index).inserted, file.index >= 0,
                  !file.path[0].hasPrefix(".torrenza-"),
                  file.path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") && !$0.contains(":") }) else {
                throw TorrentError.storage("Unsafe torrent file path or layout")
            }
            let (next, overflow) = total.addingReportingOverflow(file.length)
            guard !overflow else { throw TorrentError.storage("Torrent size overflow") }; total = next
            let key = file.path.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            if !file.isPadding { guard names.insert(key).inserted else { throw TorrentError.storage("Colliding torrent file paths") } }
        }
        for name in names {
            let components = name.split(separator: "/")
            for count in 1..<components.count where names.contains(components.prefix(count).joined(separator: "/")) {
                throw TorrentError.storage("A torrent file is also used as a directory")
            }
        }
        let expected = total == 0 ? 0 : (total - 1) / Int64(meta.pieceLength) + 1
        guard expected == meta.pieceHashes.count, meta.pieceHashes.isValid else { throw TorrentError.storage("Piece count does not match content length") }
    }
    func failure(_ action: String) -> TorrentError { .storage("\(action): \(String(cString: strerror(errno)))") }
    func prepare() throws {
        if prepared { return }
        rootFD = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw failure("Open destination") }
        var newlyCreated: [String: (UInt64, UInt64)] = [:]
        do {
            var rootStat = stat(); guard fstat(rootFD, &rootStat) == 0 else { throw failure("Inspect destination") }
            rootIdentity = (UInt64(rootStat.st_dev), rootStat.st_ino)
            buildLayout()
            // Check all existing entries before creating any payload files.
            for path in fileLengths.keys.sorted() { try preflight(path.split(separator: "/").map(String.init)) }
            for (path, length) in fileLengths.sorted(by: { $0.key < $1.key }) {
                let components = path.split(separator: "/").map(String.init)
                // Saved sessions require their existing payload and boundary data.
                // New imports can still create sidecars for future downloads.
                let existingPayload = path.hasPrefix(".torrenza-") ? requireExistingSidecars : requireExistingPayload
                let parent = try directory(Array(components.dropLast()), create: !existingPayload); defer { Darwin.close(parent) }
                var created = !existingPayload
                var fd = existingPayload
                    ? openat(parent, components.last!, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                    : openat(parent, components.last!, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL, 0o600)
                if !existingPayload && fd < 0 && errno == EEXIST && allowExisting {
                    created = false
                    fd = openat(parent, components.last!, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                }
                guard fd >= 0 else { throw failure("\(existingPayload ? "Open" : "Create") \(path)") }; defer { Darwin.close(fd) }
                var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw TorrentError.storage("Destination is not a regular file") }
                if created { newlyCreated[path] = (UInt64(info.st_dev), info.st_ino) }
                if !created && info.st_size != length { throw TorrentError.storage("Existing file size does not match torrent: \(path)") }
                if created {
                    guard ftruncate(fd, length) == 0 else { throw failure("Size \(path)") }
                    dirty.insert(path)
                    dirtyDirectories.insert(components.dropLast().joined(separator: "/"))
                }
                identities[path] = (UInt64(info.st_dev), info.st_ino)
            }
            prepared = true
        } catch {
            // Do not strand half-created payloads after failed preparation, and never
            // remove pre-existing or concurrently replaced files while rolling back.
            for (path, identity) in newlyCreated {
                let components = path.split(separator: "/").map(String.init)
                guard let parent = try? directory(Array(components.dropLast()), create: false) else { continue }
                var info = stat()
                if fstatat(parent, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
                   UInt64(info.st_dev) == identity.0, info.st_ino == identity.1 { _ = unlinkat(parent, components.last!, 0) }
                Darwin.close(parent)
            }
            close(); throw error
        }
    }
    func buildLayout() {
        segments = []; fileLengths = [:]
        var wanted: [Range<Int64>] = []
        let piece = Int64(meta.pieceLength)
        for file in meta.files where selected.contains(file.index) && !file.isPadding && file.length > 0 {
            let end = file.offset + file.length
            let start = file.offset / piece * piece
            let lastPieceStart = (end - 1) / piece * piece
            let upper = lastPieceStart + min(piece, totalLength - lastPieceStart)
            if let last = wanted.last, start <= last.upperBound { wanted[wanted.count - 1] = last.lowerBound..<max(last.upperBound, upper) }
            else { wanted.append(start..<upper) }
        }
        var sidecarOffset: Int64 = 0
        let selection = Data(selected.sorted().map(String.init).joined(separator: ",").utf8)
        let selectionHash = Data(SHA256.hash(data: selection)).hexString
        let sidecar = ".torrenza-\(meta.id)-\(selectionHash).parts"
        var wantedIndex = 0
        for file in meta.files {
            let range = file.offset..<(file.offset + file.length)
            while wantedIndex < wanted.count && wanted[wantedIndex].upperBound <= range.lowerBound { wantedIndex += 1 }
            if file.isPadding { segments.append(Segment(range: range, path: nil, fileOffset: 0)) }
            else if selected.contains(file.index) {
                segments.append(Segment(range: range, path: file.path, fileOffset: 0))
                fileLengths[file.path.joined(separator: "/")] = file.length
            } else {
                var index = wantedIndex
                while index < wanted.count && wanted[index].lowerBound < range.upperBound {
                    let desired = wanted[index]
                    let start = max(range.lowerBound, desired.lowerBound), end = min(range.upperBound, desired.upperBound)
                    if end > start { segments.append(Segment(range: start..<end, path: [sidecar], fileOffset: sidecarOffset)); sidecarOffset += end - start }
                    index += 1
                }
            }
        }
        if sidecarOffset > 0 { fileLengths[sidecar] = sidecarOffset }
    }
    func directory(_ components: [String], create: Bool) throws -> Int32 {
        var fd = dup(rootFD); guard fd >= 0 else { throw failure("Open destination directory") }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw failure("Create folder") }
                    dirtyDirectories.insert(components.prefix(index).joined(separator: "/"))
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("Open safe folder") }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    func preflight(_ components: [String]) throws {
        var fd = dup(rootFD); guard fd >= 0 else { throw failure("Inspect folder") }; defer { Darwin.close(fd) }
        for component in components.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT { return }
            guard next >= 0 else { throw failure("Unsafe destination folder") }
            Darwin.close(fd); fd = next
        }
        var info = stat()
        if fstatat(fd, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard allowExisting, (info.st_mode & S_IFMT) == S_IFREG else { throw TorrentError.storage("Refusing to overwrite existing file: \(components.joined(separator: "/"))") }
        } else if errno != ENOENT { throw failure("Inspect destination file") }
    }
    func checkDestination() throws {
        guard prepared, rootFD >= 0, let rootIdentity else { throw TorrentError.storage("Storage is not prepared") }
        var info = stat()
        guard lstat(destination.path, &info) == 0, UInt64(info.st_dev) == rootIdentity.0, info.st_ino == rootIdentity.1 else { throw TorrentError.storage("Destination was removed or replaced") }
    }
    func descriptor(_ components: [String]) throws -> Int32 {
        let path = components.joined(separator: "/")
        // Re-open parent traversal to detect renamed/replaced paths even when the payload fd is cached.
        let parent = try directory(Array(components.dropLast()), create: false); defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, let expected = identities[path],
              UInt64(info.st_dev) == expected.0, info.st_ino == expected.1 else { throw TorrentError.storage("Torrent file was removed or replaced") }
        if let fd = cache[path] { return fd }
        let fd = openat(parent, components.last!, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Open torrent file") }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { Darwin.close(fd); throw TorrentError.storage("Torrent file changed during opening") }
        if cache.count >= 32, let first = cacheOrder.first { if let old = cache.removeValue(forKey: first) { Darwin.close(old) }; cacheOrder.removeFirst() }
        cache[path] = fd; cacheOrder.append(path); return fd
    }
    func validateRange(_ offset: Int64, _ length: Int) throws {
        guard offset >= 0, length >= 0, length <= Self.maxOperation, offset <= totalLength, Int64(length) <= totalLength - offset else { throw TorrentError.storage("Invalid or oversized disk operation") }
    }
    func write(offset: Int64, data: Data) throws {
        try checkDestination(); try validateRange(offset, data.count)
        let end = offset + Int64(data.count)
        for segment in overlapping(offset..<end) {
            let start = max(offset, segment.range.lowerBound), upper = min(end, segment.range.upperBound)
            guard let path = segment.path else { continue }
            let fd = try descriptor(path)
            dirty.insert(path.joined(separator: "/"))
            try data.withUnsafeBytes { raw in
                var done = 0; let count = Int(upper - start)
                while done < count {
                    let result = pwrite(fd, raw.baseAddress!.advanced(by: Int(start - offset) + done), count - done, segment.fileOffset + start - segment.range.lowerBound + Int64(done))
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw failure("Write torrent block") }; done += result
                }
            }
        }
    }
    func read(offset: Int64, length: Int) throws -> Data {
        try checkDestination(); try validateRange(offset, length)
        var output = Data(count: length); var covered = 0
        let end = offset + Int64(length)
        for segment in overlapping(offset..<end) {
            let start = max(offset, segment.range.lowerBound), upper = min(end, segment.range.upperBound)
            let count = Int(upper - start); covered += count
            guard let path = segment.path else { continue }
            let fd = try descriptor(path)
            try output.withUnsafeMutableBytes { raw in
                var done = 0
                while done < count {
                    let result = pread(fd, raw.baseAddress!.advanced(by: Int(start - offset) + done), count - done, segment.fileOffset + start - segment.range.lowerBound + Int64(done))
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw TorrentError.storage("Torrent data is unavailable or truncated") }; done += result
                }
            }
        }
        guard covered == length else { throw TorrentError.storage("Requested data belongs to an unselected piece") }
        return output
    }
    func overlapping(_ range: Range<Int64>) -> ArraySlice<Segment> {
        guard !range.isEmpty else { return segments[0..<0] }
        var low = 0, high = segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].range.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < segments.count && segments[end].range.lowerBound < range.upperBound { end += 1 }
        return segments[low..<end]
    }
    func verifyPiece(_ index: Int) throws -> Bool {
        guard meta.pieceHashes.indices.contains(index) else { throw TorrentError.storage("Invalid piece index") }
        var hash = Insecure.SHA1(); let start = Int64(index) * Int64(meta.pieceLength)
        let length = Int(min(Int64(meta.pieceLength), totalLength - start)); var done = 0
        while done < length { let size = min(65_536, length - done); hash.update(data: try read(offset: start + Int64(done), length: size)); done += size }
        return Data(hash.finalize()) == meta.pieceHashes[index]
    }
    func flush() throws {
        // Paused/completed transfers must not wake an idle external disk on each checkpoint.
        guard !dirty.isEmpty || !dirtyDirectories.isEmpty else { return }
        try checkDestination()
        // Open each file as needed; cache eviction must not prevent checkpoint durability.
        for path in dirty.sorted() { let fd = try descriptor(path.split(separator: "/").map(String.init)); guard fsync(fd) == 0 else { throw failure("Flush torrent data") } }
        for path in dirtyDirectories.sorted() {
            let fd = try directory(path.split(separator: "/").map(String.init), create: false); defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw failure("Flush destination folder") }
        }
        guard fsync(rootFD) == 0 else { throw failure("Flush destination directory") }
        dirty.removeAll(keepingCapacity: true)
        dirtyDirectories.removeAll(keepingCapacity: true)
    }
    func signatures() throws -> [DiskSignature] {
        try checkDestination()
        return try fileLengths.keys.sorted().map { path in
            let fd = try descriptor(path.split(separator: "/").map(String.init)); var info = stat()
            guard fstat(fd, &info) == 0 else { throw failure("Inspect torrent data") }
            return DiskSignature(path: path, device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
        }
    }
    func close() {
        for fd in cache.values { Darwin.close(fd) }; cache = [:]; cacheOrder = []
        if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }; prepared = false
    }
    func deleteFiles() throws {
        try checkDestination()
        // Validate the entire set before deleting the first path.
        for path in fileLengths.keys.sorted() { _ = try descriptor(path.split(separator: "/").map(String.init)) }
        for path in fileLengths.keys.sorted() {
            let components = path.split(separator: "/").map(String.init)
            let parent = try directory(Array(components.dropLast()), create: false); defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  let identity = identities[path], UInt64(info.st_dev) == identity.0, info.st_ino == identity.1 else { throw TorrentError.storage("Refusing to remove a replaced file") }
            guard unlinkat(parent, components.last!, 0) == 0 else { throw failure("Remove torrent file") }
            guard fsync(parent) == 0 else { throw failure("Flush removed file") }
        }
        close()
    }
}
