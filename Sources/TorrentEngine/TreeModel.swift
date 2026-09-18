import Foundation
import TorrentCore

/// Presentation-only hierarchy. It never enumerates the destination filesystem.
@MainActor public final class TorrentTreeNode: Identifiable {
    public enum Kind: Equatable { case volume, folder, torrent(String), file(String, Int), resolving }
    public let id: String
    public let name: String
    public let url: URL?
    public let kind: Kind
    public let transferIDs: Set<String>
    public let fileIndices: [Int]?
    public let expandable: Bool
    private var cachedChildren: [TorrentTreeNode]?
    private let makeChildren: () -> [TorrentTreeNode]
    public var children: [TorrentTreeNode] {
        if let cachedChildren { return cachedChildren }
        let result = makeChildren(); cachedChildren = result; return result
    }
    public init(id: String, name: String, url: URL?, kind: Kind, transferIDs: Set<String>, fileIndices: [Int]? = nil, expandable: Bool, children: @escaping () -> [TorrentTreeNode] = { [] }) {
        self.id = id; self.name = name; self.url = url; self.kind = kind
        self.transferIDs = transferIDs; self.fileIndices = fileIndices; self.expandable = expandable; makeChildren = children
    }
}

public enum TreeFilter: String, CaseIterable, Sendable { case all = "All Transfers", active = "Active", downloading = "Downloading", completed = "Completed", paused = "Paused", attention = "Needs Attention" }
public struct TreeMetrics: Equatable, Sendable {
    public var size: Int64 = 0
    public var verified: Int64 = 0
    public var downloadRate: Double = 0
    public var uploadRate: Double = 0
    public var progress: Double { size > 0 ? min(1, Double(verified) / Double(size)) : 0 }
    public init() {}
}

@MainActor public final class TorrentTreeModel {
    public private(set) var roots: [TorrentTreeNode] = []
    public private(set) var transfers: [String: TransferSnapshot] = [:]
    public private(set) var generation = 0
    private struct Structure: Equatable {
        let id: String
        let name: String
        let destination: URL?
        let isMultiFile: Bool
        let fileCount: Int
        let matchesFilter: Bool
    }
    private var structure: [Structure] = []
    private var fileOffsets: [String: [Int: Int]] = [:]
    private var lastSearch = ""
    private var lastFilter: TreeFilter = .all
    private let startupVolumeName: String
    public init(startupVolumeName: String = "Startup Disk") { self.startupVolumeName = startupVolumeName }

    /// Rate/progress updates retain node identity and do not rebuild the hierarchy.
    @discardableResult public func update(_ snapshots: [TransferSnapshot], search: String = "", filter: TreeFilter = .all) -> Bool {
        transfers = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Torrent IDs are info hashes: their file paths and layout are immutable.
        // Compare only transfer topology, never all file paths on each progress tick.
        let nextStructure = snapshots.map {
            Structure(id: $0.id, name: $0.name, destination: $0.destination,
                      isMultiFile: $0.isMultiFile, fileCount: $0.files.count,
                      matchesFilter: Self.matches($0, filter: filter))
        }
        let changed = term != lastSearch || filter != lastFilter || nextStructure != structure
        guard changed else { return false }
        structure = nextStructure; lastSearch = term; lastFilter = filter; generation += 1
        fileOffsets = Dictionary(uniqueKeysWithValues: snapshots.map { transfer in
            (transfer.id, Dictionary(transfer.files.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }))
        })
        let selected = snapshots.filter { Self.matches($0, filter: filter) && Self.matches($0, search: term) }
        let located = selected.filter { $0.destination != nil }
        let groups = Dictionary(grouping: located) { Self.volume(for: $0.destination!).path }
        roots = groups.keys.sorted().map { path in
            let items = groups[path]!
            let volume = Self.volume(for: items[0].destination!)
            return TorrentTreeNode(id: "volume:\(path)", name: path == "/" ? startupVolumeName : volume.name, url: URL(fileURLWithPath: path), kind: .volume, transferIDs: Set(items.map(\.id)), expandable: true) {
                Self.locationChildren(items, at: URL(fileURLWithPath: path), search: term)
            }
        }
        let resolving = selected.filter { $0.destination == nil }
        if !resolving.isEmpty {
            roots.insert(TorrentTreeNode(id: "resolving", name: "Resolving Metadata", url: nil, kind: .resolving, transferIDs: Set(resolving.map(\.id)), expandable: true) {
                resolving.map { Self.torrentNode($0, search: term) }
            }, at: 0)
        }
        return true
    }

    /// File indices can be sparse when padding entries are omitted from snapshots.
    public func file(transferID: String, index: Int) -> FileSnapshot? {
        guard let transfer = transfers[transferID], let offset = fileOffsets[transferID]?[index],
              transfer.files.indices.contains(offset) else { return nil }
        return transfer.files[offset]
    }

    public func metrics(for node: TorrentTreeNode) -> TreeMetrics {
        var result = TreeMetrics()
        for id in node.transferIDs {
            guard let transfer = transfers[id] else { continue }
            if let indices = node.fileIndices {
                for index in indices {
                    guard let file = file(transferID: id, index: index), file.selected else { continue }
                    result.size += file.file.length; result.verified += file.verifiedBytes
                }
            } else {
                result.size += transfer.selectedBytes; result.verified += transfer.completedBytes
                result.downloadRate += transfer.downloadRate; result.uploadRate += transfer.uploadRate
            }
        }
        return result
    }

    public static func contentURL(_ transfer: TransferSnapshot) -> URL? {
        transfer.destination?.appendingPathComponent(transfer.name, isDirectory: transfer.isMultiFile)
    }
    public static func fileURL(_ file: TorrentFile, in transfer: TransferSnapshot) -> URL? {
        guard let base = transfer.destination else { return nil }
        return file.path.reduce(base) { $0.appendingPathComponent($1) }
    }
    private static func matches(_ transfer: TransferSnapshot, filter: TreeFilter) -> Bool {
        switch filter {
        case .all: true
        case .active: [.downloading, .seeding, .checking, .resolving].contains(transfer.state)
        case .downloading: [.downloading, .queued, .resolving].contains(transfer.state)
        case .completed: [.completed, .seeding].contains(transfer.state)
        case .paused: transfer.state == .paused
        case .attention: [.unavailable, .failed].contains(transfer.state)
        }
    }
    private static func matches(_ transfer: TransferSnapshot, search: String) -> Bool {
        search.isEmpty || transfer.name.localizedStandardContains(search) || (transfer.destination?.path.localizedStandardContains(search) ?? false) || transfer.files.contains { $0.file.path.joined(separator: "/").localizedStandardContains(search) }
    }
    private static func volume(for url: URL) -> (path: String, name: String) {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3 && parts[1] == "Volumes" { return ("/Volumes/\(parts[2])", parts[2]) }
        return ("/", "Startup Disk")
    }
    private static func locationChildren(_ transfers: [TransferSnapshot], at parent: URL, search: String) -> [TorrentTreeNode] {
        let parentComponents = parent.standardizedFileURL.pathComponents
        var direct: [TransferSnapshot] = []
        var groups: [String: [TransferSnapshot]] = [:]
        for transfer in transfers {
            guard let destination = transfer.destination?.standardizedFileURL else { continue }
            let parts = destination.pathComponents
            if parts.count == parentComponents.count { direct.append(transfer) }
            else if parts.count > parentComponents.count { groups[parts[parentComponents.count], default: []].append(transfer) }
        }
        var children = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = groups[name]!, url = parent.appendingPathComponent(name, isDirectory: true)
            return TorrentTreeNode(id: "folder:\(url.path)", name: name, url: url, kind: .folder, transferIDs: Set(group.map(\.id)), expandable: true) { locationChildren(group, at: url, search: search) }
        }
        children += direct.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { torrentNode($0, search: search) }
        return children
    }
    private static func torrentNode(_ transfer: TransferSnapshot, search: String) -> TorrentTreeNode {
        let files = transfer.files.map(\.file).filter { !$0.isPadding }
        // A match on a torrent or destination shows its complete subtree. Otherwise keep matching file paths and their ancestors.
        let fileSearch = transfer.name.localizedStandardContains(search) || (transfer.destination?.path.localizedStandardContains(search) ?? false) ? "" : search
        let visibleFiles = files.filter { fileSearch.isEmpty || $0.path.joined(separator: "/").localizedStandardContains(fileSearch) }
        return TorrentTreeNode(id: "torrent:\(transfer.id)", name: transfer.name, url: contentURL(transfer), kind: .torrent(transfer.id), transferIDs: [transfer.id], expandable: transfer.isMultiFile && !visibleFiles.isEmpty) {
            guard transfer.isMultiFile else { return [] }
            return fileChildren(visibleFiles, transfer: transfer, depth: 1, path: [])
        }
    }
    private static func fileChildren(_ files: [TorrentFile], transfer: TransferSnapshot, depth: Int, path: [String]) -> [TorrentTreeNode] {
        let groups = Dictionary(grouping: files.filter { $0.path.count > depth }) { $0.path[depth] }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = groups[name]!, next = path + [name]
            let url = next.reduce(contentURL(transfer)!) { $0.appendingPathComponent($1) }
            if group.count == 1, let file = group.first, file.path.count == depth + 1 {
                return TorrentTreeNode(id: "file:\(transfer.id):\(file.index)", name: name, url: url, kind: .file(transfer.id, file.index), transferIDs: [transfer.id], fileIndices: [file.index], expandable: false)
            }
            return TorrentTreeNode(id: "contents:\(transfer.id):\(next.joined(separator: "/"))", name: name, url: url, kind: .folder, transferIDs: [transfer.id], fileIndices: group.map(\.index), expandable: true) {
                fileChildren(group, transfer: transfer, depth: depth + 1, path: next)
            }
        }
    }
}
