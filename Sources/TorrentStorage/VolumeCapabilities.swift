import Foundation
import Darwin
import IOKit
import Synchronization

/// Inspect once when opening a destination; retain the result with the transfer.
/// An unknown medium intentionally receives the conservative HDD policy.
public struct VolumeCapabilities: Sendable, Equatable {
    public let identity: String
    public let isSolidState: Bool?

    private static let cache = VolumeMediumCache()

    public static func inspect(destination: URL) -> VolumeCapabilities {
        var mount = statfs()
        guard statfs(destination.path, &mount) == 0 else {
            return VolumeCapabilities(identity: "unavailable:\(destination.standardizedFileURL.path)", isSolidState: nil)
        }
        let source = string(mount.f_mntfromname)
        let resources = try? destination.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey])
        let filesystemID = "\(mount.f_fsid.val.0):\(mount.f_fsid.val.1)"
        let identity = makeIdentity(volumeUUID: resources?.volumeUUIDString, mountSource: source, filesystemID: filesystemID)
        // A remount may expose different physical backing despite retaining a UUID.
        let medium = cache.value(for: "\(identity)|\(source)|\(filesystemID)") {
            guard resources?.volumeIsLocal != false, source.hasPrefix("/dev/") else { return nil }
            return classify(backingMedia: physicalMedia(bsdName: String(source.dropFirst(5))))
        }
        return VolumeCapabilities(identity: identity, isSolidState: medium)
    }

    static func makeIdentity(volumeUUID: String?, mountSource: String, filesystemID: String) -> String {
        if let volumeUUID, !volumeUUID.isEmpty { return "uuid:\(volumeUUID.lowercased())" }
        // Mount IDs are deliberately included: without a UUID, a remounted device
        // must not silently inherit trusted resume state from the same display name.
        return "mount:\(mountSource)|\(filesystemID)"
    }

    static func classify(backingMedia: [String?]) -> Bool? {
        guard !backingMedia.isEmpty,
              backingMedia.allSatisfy({ $0 == "Solid State" || $0 == "Rotational" }) else { return nil }
        return backingMedia.allSatisfy { $0 == "Solid State" }
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Follows *all* registry parents to physical devices. APFS/Fusion/RAID layers
    /// that do not expose unambiguous backing media stay unknown; filesystem type
    /// and external/internal attachment alone never imply SSD or HDD.
    private static func physicalMedia(bsdName: String) -> [String?] {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return [] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return [] }
        var entries = [service], visited = Set<UInt64>(), result: [String?] = []
        defer { for entry in entries { IOObjectRelease(entry) } }
        var index = 0
        while index < entries.count {
            guard entries.count <= 256 else { return [] }
            let entry = entries[index]; index += 1
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else { return [] }
            guard visited.insert(registryID).inserted else { continue }
            if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                let value = IORegistryEntryCreateCFProperty(entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                let characteristics = value as? [String: Any]
                result.append(characteristics?["Medium Type"] as? String)
                continue
            }
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
            while true {
                let parent = IOIteratorNext(iterator)
                if parent == 0 { break }
                entries.append(parent)
            }
            IOObjectRelease(iterator)
        }
        return result
    }
}

/// Caches unknown results too, preventing repeated registry traversal for logical
/// volumes whose backing storage is intentionally not exposed by macOS.
final class VolumeMediumCache: Sendable {
    private struct Result: Sendable { let medium: Bool? }
    private let values = Mutex<[String: Result]>([:])

    func value(for identity: String, probe: () -> Bool?) -> Bool? {
        values.withLock { stored in
            if let value = stored[identity] { return value.medium }
            let result = Result(medium: probe())
            if stored.count >= 256 { stored.removeAll(keepingCapacity: true) }
            stored[identity] = result
            return result.medium
        }
    }
}
