import Foundation
import TorrentCore

public enum TransferActionTarget: Equatable, Sendable {
    case torrent
    case files(Set<Int>)
}

/// Resolves presentation nodes against complete metadata, never the destination filesystem.
@MainActor public enum TorrentTreeActions {
    public static func resolve(_ nodes: [TorrentTreeNode], transfers: [TransferSnapshot]) -> [String: TransferActionTarget] {
        let snapshots = Dictionary(transfers.filter { $0.state != .resolving }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var result: [String: TransferActionTarget] = [:]
        for node in nodes {
            if let selection = fileSelection(for: node, snapshots: snapshots) {
                switch result[selection.id] {
                case .torrent: break
                case .files(let existing): result[selection.id] = .files(existing.union(selection.indices))
                case nil: result[selection.id] = .files(selection.indices)
                }
            } else {
                // A stale or invalid file/content-folder node must not widen into a torrent action.
                if case .file = node.kind { continue }
                if node.id.hasPrefix("contents:") { continue }
                for id in node.transferIDs where snapshots[id] != nil { result[id] = .torrent }
            }
        }
        return result
    }

    /// Single-file torrents and torrent-internal folders expose file controls.
    /// Folder indices include descendants hidden by search and exclude padding entries.
    public static func fileSelection(for node: TorrentTreeNode, transfers: [TransferSnapshot]) -> (id: String, indices: Set<Int>)? {
        fileSelection(for: node, snapshots: Dictionary(transfers.filter { $0.state != .resolving }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }))
    }

    private static func fileSelection(for node: TorrentTreeNode, snapshots: [String: TransferSnapshot]) -> (id: String, indices: Set<Int>)? {
        switch node.kind {
        case .file(let id, let index):
            guard let transfer = snapshots[id], transfer.files.contains(where: { $0.id == index && !$0.file.isPadding }) else { return nil }
            return (id, [index])
        case .torrent(let id):
            guard let transfer = snapshots[id], !transfer.isMultiFile else { return nil }
            let indices = Set(transfer.files.filter { !$0.file.isPadding }.map(\.id))
            return indices.isEmpty ? nil : (id, indices)
        case .folder:
            guard node.transferIDs.count == 1, let id = node.transferIDs.first,
                  let transfer = snapshots[id] else { return nil }
            let prefix = "contents:\(id):"
            guard node.id.hasPrefix(prefix) else { return nil }
            let path = String(node.id.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else { return nil }
            let indices = Set(transfer.files.filter { file in
                !file.file.isPadding && file.file.path.dropFirst().starts(with: path)
            }.map(\.id))
            return indices.isEmpty ? nil : (id, indices)
        case .volume, .resolving:
            return nil
        }
    }
}

/// Snapshot-scoped lookup shared by visible name cells. Indexes are built only for
/// transfers whose file controls are requested, and released with this resolver.
@MainActor public final class TorrentTreeSelectionIndex {
    public enum State: Equatable { case off, on, mixed }
    private struct Files {
        var selected: [Int: Bool] = [:]
        var folders: [[String]: Set<Int>] = [:]
    }
    private let snapshots: [String: TransferSnapshot]
    private let overrides: [String: [Int: Bool]]
    private var indexed: [String: Files] = [:]

    public init(transfers: [TransferSnapshot], overrides: [String: [Int: Bool]] = [:]) {
        snapshots = Dictionary(transfers.filter { $0.state != .resolving }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.overrides = overrides
    }

    private func files(for id: String) -> Files? {
        if let cached = indexed[id] { return cached }
        guard let snapshot = snapshots[id] else { return nil }
        var files = Files()
        for file in snapshot.files where !file.file.isPadding {
            files.selected[file.id] = overrides[id]?[file.id] ?? file.selected
            let components = Array(file.file.path.dropFirst())
            // Match the action resolver's component-prefix semantics exactly.
            for end in components.indices {
                files.folders[Array(components.prefix(end + 1)), default: []].insert(file.id)
            }
        }
        indexed[id] = files
        return files
    }

    public func fileSelection(for node: TorrentTreeNode) -> (id: String, indices: Set<Int>)? {
        switch node.kind {
        case .file(let id, let index):
            guard files(for: id)?.selected[index] != nil else { return nil }
            return (id, [index])
        case .torrent(let id):
            guard snapshots[id]?.isMultiFile == false, let files = files(for: id), !files.selected.isEmpty else { return nil }
            return (id, Set(files.selected.keys))
        case .folder:
            guard node.transferIDs.count == 1, let id = node.transferIDs.first else { return nil }
            let prefix = "contents:\(id):"
            guard node.id.hasPrefix(prefix) else { return nil }
            let path = String(node.id.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }), let indices = files(for: id)?.folders[path], !indices.isEmpty else { return nil }
            return (id, indices)
        case .volume, .resolving: return nil
        }
    }

    public func state(for node: TorrentTreeNode) -> State? {
        guard let selection = fileSelection(for: node), let files = files(for: selection.id) else { return nil }
        var anySelected = false, anyUnselected = false
        for index in selection.indices {
            if files.selected[index] == true { anySelected = true } else { anyUnselected = true }
            if anySelected && anyUnselected { return .mixed }
        }
        return anySelected ? .on : .off
    }
}
