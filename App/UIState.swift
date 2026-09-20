import AppKit
import TorrentEngine

enum AppAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
}

struct UIState: Codable, Equatable {
    var version = 1
    var notificationsEnabled = false
    var filter = TreeFilter.all.rawValue
    var inspectorVisible = false
    var expandedNodeIDs: [String] = []
    var hasSavedExpansion = false
    var selectedNodeID: String?
    var selectedNodeIDs: [String]?
    var effectiveSelectedNodeIDs: [String] { selectedNodeIDs ?? selectedNodeID.map { [$0] } ?? [] }
    var columnOrder: [String] = []
    var columnWidths: [String: Double] = [:]
    var sortOrder: TreeSortOrder?
    // Optional so existing profile state decodes without losing saved interface preferences.
    var appearance: AppAppearance?
    // Dialog starting locations only; choosing a folder still grants access through NSOpenPanel.
    var lastTorrentDirectory: URL?
    var lastDestinationDirectory: URL?
}

@MainActor extension AppModel {
    var appearance: AppAppearance {
        get { uiState.appearance ?? .system }
        set { uiState.appearance = newValue }
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Old app-owned preferences are read only for migration; SQLite owns all subsequent writes.
    func migrateLegacyUIState() -> (state: UIState, keys: [String]) {
        let defaults = profileDefaults
        var state = UIState()
        state.notificationsEnabled = defaults.bool(forKey: "completionNotifications")
        state.expandedNodeIDs = defaults.stringArray(forKey: "expandedTreeNodes") ?? []
        state.hasSavedExpansion = defaults.object(forKey: "expandedTreeNodes") != nil
        state.selectedNodeID = defaults.string(forKey: "selectedTreeNode")
        var keys = ["completionNotifications", "expandedTreeNodes", "selectedTreeNode"]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("NSTableView Columns TorrentColumns") || key.hasPrefix("NSTableView Sort Ordering TorrentColumns") {
            keys.append(key)
            guard let columns = value as? [[String: Any]] else { continue }
            for column in columns {
                let identifier = column.first { $0.key.lowercased().contains("identifier") }?.value as? String
                let width = column.first { $0.key.lowercased().contains("width") }?.value as? NSNumber
                if let identifier {
                    state.columnOrder.append(identifier)
                    if let width, width.doubleValue.isFinite, width.doubleValue > 0 { state.columnWidths[identifier] = width.doubleValue }
                }
            }
        }
        return (state, keys)
    }
}
