import Darwin
import Foundation

public struct ProfileDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL

    public var databaseURL: URL { directory.appendingPathComponent("Torrenza.sqlite") }

    public init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public enum ProfileStoreError: Error, LocalizedError, Sendable {
    case invalidName
    case duplicateName
    case invalidLocation
    case missingProfile

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a profile name between 1 and 80 characters, without control characters."
        case .duplicateName: "A profile with this name already exists."
        case .invalidLocation: "The profile location must be a local directory without symbolic links."
        case .missingProfile: "This profile is no longer available."
        }
    }
}

/// Each database owns its name and contents. The original library remains the default profile,
/// so enabling profiles does not move existing databases or legacy migration inputs.
public actor ProfileStore {
    private struct Metadata: Codable { let name: String }
    private let root: URL
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func list() async throws -> [ProfileDescriptor] {
        await acquire()
        defer { release() }
        return try await listUnlocked()
    }

    public func create(name: String) async throws -> ProfileDescriptor {
        await acquire()
        defer { release() }
        let name = try validatedName(name)
        let profiles = try await listUnlocked()
        try ensureUnique(name, profiles: profiles)
        let parent = root.appendingPathComponent("Profiles", isDirectory: true)
        try ensureDirectory(parent, create: true)
        let id = UUID().uuidString
        let directory = parent.appendingPathComponent(id, isDirectory: true)
        // No name supplied by the user ever becomes a filesystem path.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let profile = ProfileDescriptor(id: id, name: name, directory: directory)
        do {
            try await writeMetadata(profile)
            return profile
        } catch {
            // This newly allocated UUID directory belongs exclusively to this operation.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @discardableResult
    public func rename(profile: ProfileDescriptor, name: String) async throws -> ProfileDescriptor {
        await acquire()
        defer { release() }
        let name = try validatedName(name)
        let profiles = try await listUnlocked()
        guard let current = profiles.first(where: { $0.id == profile.id }),
              current.directory.standardizedFileURL == profile.directory.standardizedFileURL else {
            throw ProfileStoreError.missingProfile
        }
        try ensureUnique(name, profiles: profiles.filter { $0.id != current.id })
        let renamed = ProfileDescriptor(id: current.id, name: name, directory: current.directory)
        try await writeMetadata(renamed)
        return renamed
    }

    private func listUnlocked() async throws -> [ProfileDescriptor] {
        guard root.isFileURL, !root.path.utf8.contains(0) else { throw ProfileStoreError.invalidLocation }
        try ensureDirectory(root, create: true)
        let original = ProfileDescriptor(id: "default", name: "Default", directory: root)
        var originalName: String?
        do {
            originalName = try await readMetadata(original)
            if originalName == nil { try await writeMetadata(original) }
        } catch {
            // Keep a damaged library visible and leave it untouched. Activation reports the error.
            originalName = nil
        }
        var profiles = [ProfileDescriptor(id: original.id, name: originalName ?? original.name, directory: root)]
        let parent = root.appendingPathComponent("Profiles", isDirectory: true)
        if try fileType(parent) != nil {
            try ensureDirectory(parent, create: false)
            for id in try FileManager.default.contentsOfDirectory(atPath: parent.path) {
                let directory = parent.appendingPathComponent(id, isDirectory: true)
                guard UUID(uuidString: id) != nil, try fileType(directory) == S_IFDIR else { continue }
                let candidate = ProfileDescriptor(id: id, name: "", directory: directory)
                // Do not create empty databases when discovering unrelated or incomplete folders.
                guard try fileType(candidate.databaseURL) == S_IFREG else { continue }
                do {
                    guard let name = try await readMetadata(candidate) else { continue }
                    profiles.append(ProfileDescriptor(id: id, name: name, directory: directory))
                } catch {
                    profiles.append(ProfileDescriptor(id: id, name: "Profile \(id.prefix(8))", directory: directory))
                }
            }
        }
        return [profiles[0]] + profiles.dropFirst().sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func readMetadata(_ profile: ProfileDescriptor) async throws -> String? {
        let database = SQLiteStore(url: profile.databaseURL)
        do {
            let data = try await database.read(namespace: "profile", key: "metadata")
            try await database.close()
            return try data.map { try validatedName(JSONDecoder().decode(Metadata.self, from: $0).name) }
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func writeMetadata(_ profile: ProfileDescriptor) async throws {
        let database = SQLiteStore(url: profile.databaseURL)
        do {
            try await database.write([SQLiteEntry(namespace: "profile", key: "metadata",
                                                 value: try JSONEncoder().encode(Metadata(name: profile.name)))])
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func validatedName(_ source: String) throws -> String {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProfileStoreError.invalidName
        }
        return name
    }

    private func ensureUnique(_ name: String, profiles: [ProfileDescriptor]) throws {
        guard !profiles.contains(where: { $0.name.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame }) else {
            throw ProfileStoreError.duplicateName
        }
    }

    private func fileType(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func ensureDirectory(_ url: URL, create: Bool) throws {
        if try fileType(url) == nil, create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard try fileType(url) == S_IFDIR else { throw ProfileStoreError.invalidLocation }
    }

    // Actor isolation alone does not serialize a check-and-write sequence across SQLite awaits.
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
