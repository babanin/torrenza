import Foundation
import Darwin
import TorrentCore

extension TorrentDisk {
    /// Validates persisted ownership across all selections without trusting names alone.
    /// Returns current signatures, rebasing a remounted device only on the recorded volume.
    @discardableResult
    public static func validateOwnedFiles(destination: URL, signatures: [DiskSignature], allowMissing: Bool = true, expectedVolumeUUID: String? = nil) async throws -> [DiskSignature] {
        try await OwnedFiles.perform {
            let operation = try OwnedFiles(destination: destination, expectedVolumeUUID: expectedVolumeUUID)
            return try operation.validate(signatures, allowMissing: allowMissing)
        }
    }

    /// Removes only recorded file identities, including sidecars from older selections.
    /// Missing files are harmless; a single replaced file prevents the initial deletion pass.
    public static func removeOwnedFiles(destination: URL, signatures: [DiskSignature], expectedVolumeUUID: String? = nil) async throws {
        guard !signatures.isEmpty else { return }
        try await OwnedFiles.perform {
            let operation = try OwnedFiles(destination: destination, expectedVolumeUUID: expectedVolumeUUID)
            try operation.remove(signatures)
        }
    }

    public static func currentSignature(destination: URL, path: [String]) async throws -> DiskSignature? {
        try await OwnedFiles.perform {
            let operation = try OwnedFiles(destination: destination)
            return try operation.signature(path)
        }
    }
}

private final class OwnedFiles {
    private static let queue = DispatchQueue(label: "app.torrenza.ownership", qos: .utility)
    private let root: Int32
    private let verifiedVolumeDevice: UInt64?

    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    init(destination: URL, expectedVolumeUUID: String? = nil) throws {
        root = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.failure("Open destination for ownership validation") }
        do {
            if let expectedVolumeUUID {
                let current = try destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                guard current == expectedVolumeUUID else { throw TorrentError.storage("The original destination volume is unavailable") }
                var opened = stat(), currentRoot = stat()
                guard fstat(root, &opened) == 0, lstat(destination.path, &currentRoot) == 0,
                      opened.st_dev == currentRoot.st_dev, opened.st_ino == currentRoot.st_ino else {
                    throw TorrentError.storage("Destination was removed or replaced")
                }
                verifiedVolumeDevice = UInt64(opened.st_dev)
            } else { verifiedVolumeDevice = nil }
        } catch { Darwin.close(root); throw error }
    }
    deinit { if root >= 0 { Darwin.close(root) } }

    private static func failure(_ action: String) -> TorrentError { .storage("\(action): \(String(cString: strerror(errno)))") }

    private func checked(_ components: [String]) throws {
        guard !components.isEmpty, components.count <= 65,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") && !$0.contains(":") && $0.utf8.count <= 255 }),
              components.joined(separator: "/").utf8.count <= 4096 else { throw TorrentError.storage("Unsafe owned-file path") }
    }

    /// nil means a missing ancestor; unsafe ancestors are errors, never missing files.
    private func parent(_ components: [String]) throws -> Int32? {
        try checked(components)
        var fd = dup(root)
        guard fd >= 0 else { throw Self.failure("Inspect owned-file directory") }
        do {
            for component in components.dropLast() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT { Darwin.close(fd); return nil }
                guard next >= 0 else { throw Self.failure("Unsafe owned-file ancestor") }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    func signature(_ components: [String]) throws -> DiskSignature? {
        guard let fd = try parent(components) else { return nil }; defer { Darwin.close(fd) }
        return try signature(parent: fd, components: components)
    }

    private func signature(parent: Int32, components: [String]) throws -> DiskSignature? {
        var info = stat()
        if fstatat(parent, components.last!, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Self.failure("Inspect owned file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw TorrentError.storage("Owned path is not a regular file") }
        return DiskSignature(path: components.joined(separator: "/"), device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private func normalized(_ signatures: [DiskSignature]) throws -> [DiskSignature] {
        guard signatures.count <= 200_000 else { throw TorrentError.storage("Too many owned-file records") }
        var paths: [String: DiskSignature] = [:]
        for signature in signatures {
            let components = signature.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            try checked(components)
            if let previous = paths[signature.path], previous.device != signature.device || previous.inode != signature.inode {
                throw TorrentError.storage("Conflicting owned-file identities")
            }
            paths[signature.path] = signature
        }
        return paths.values.sorted { $0.path < $1.path }
    }

    private func matches(_ actual: DiskSignature, _ expected: DiskSignature) -> Bool {
        actual.device == expected.device && actual.inode == expected.inode
    }

    func validate(_ signatures: [DiskSignature], allowMissing: Bool) throws -> [DiskSignature] {
        try normalized(signatures).map { expected in
            let components = expected.path.split(separator: "/").map(String.init)
            if let actual = try signature(components) {
                // st_dev is a mount-time number, not a persistent volume identity.
                // A UUID-verified root permits renumbering, never a changed inode
                // or a file on a nested foreign mount.
                let sameVolume = verifiedVolumeDevice.map { actual.device == $0 } ?? (actual.device == expected.device)
                guard sameVolume, actual.inode == expected.inode else { throw TorrentError.storage("Refusing a replaced or unrelated file: \(expected.path)") }
                return actual
            } else if !allowMissing { throw TorrentError.storage("Owned file is missing: \(expected.path)") }
            return expected
        }
    }

    func remove(_ signatures: [DiskSignature]) throws {
        let signatures = try validate(signatures, allowMissing: true)
        var changedParents = Set<[String]>()
        for expected in signatures {
            let components = expected.path.split(separator: "/").map(String.init)
            guard let fd = try parent(components) else { continue }; defer { Darwin.close(fd) }
            guard let actual = try signature(parent: fd, components: components) else { continue }
            guard matches(actual, expected) else { throw TorrentError.storage("Refusing to remove a replaced file: \(expected.path)") }
            guard unlinkat(fd, components.last!, 0) == 0 else { throw Self.failure("Remove owned file") }
            changedParents.insert(Array(components.dropLast()))
        }
        for components in changedParents {
            // Appending an unused leaf lets the same no-follow parent traversal open the directory.
            guard let fd = try parent(components + ["unused"]) else { continue }; defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw Self.failure("Commit owned-file removal") }
        }
    }
}
