import AppKit
import SwiftUI
import TorrentCore
import TorrentEngine

struct TorrentOutlineView: NSViewRepresentable {
    @Bindable var model: AppModel
    var snapshots: [TransferSnapshot]
    var search: String
    var filter: TreeFilter
    var uiState: UIState
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let outline = NSOutlineView()
        outline.style = .inset; outline.rowSizeStyle = .medium; outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false; outline.autosaveTableColumns = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Name", 320.0), ("size", "Size", 90.0), ("progress", "Progress / Status", 180.0), ("download", "Download", 95.0), ("upload", "Upload", 95.0), ("seeds", "Seeds", 85.0), ("peers", "Peers", 85.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 180 : 65
            if id == "seeds" { column.headerToolTip = "Connected seeds / tracker-reported seeds. Estimates are not summed across trackers." }
            if id == "peers" { column.headerToolTip = "All connected peers, including seeds / tracker-reported total peers." }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.setAccessibilityLabel("Torrent filesystem tree")
        outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = context.coordinator; outline.menu = menu
        scroll.documentView = outline; context.coordinator.outline = outline
        context.coordinator.refresh(model: model)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.refresh(model: model) }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource, NSMenuDelegate {
        var model: AppModel
        weak var outline: NSOutlineView?
        var generation = -1
        var expanded: Set<String> = []
        var selectedID: String?
        var loadedState = false
        var restoring = false
        var filtering = false
        let profileID: String?
        var belongsToActiveProfile: Bool { model.activeProfile?.id == profileID }
        var canInteract: Bool { belongsToActiveProfile && model.isProfileReady && !model.isSwitchingProfile }
        var persistsState: Bool {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { return false }
            #endif
            return canInteract
        }
        init(model: AppModel) { self.model = model; profileID = model.activeProfile?.id }
        func refresh(model: AppModel) {
            guard model.activeProfile?.id == profileID else { return }
            self.model = model
            guard let outline else { return }
            if model.didLoadUIState && !loadedState {
                loadedState = true; expanded = Set(model.uiState.expandedNodeIDs); selectedID = model.uiState.selectedNodeID
                restoring = true
                for (position, id) in model.uiState.columnOrder.enumerated() where position < outline.numberOfColumns {
                    let source = outline.column(withIdentifier: .init(id))
                    if source >= 0 && source != position { outline.moveColumn(source, toColumn: position) }
                }
                for column in outline.tableColumns {
                    if let width = model.uiState.columnWidths[column.identifier.rawValue], width.isFinite { column.width = max(column.minWidth, min(1500, width)) }
                }
                restoring = false; generation = -1
            }
            model.tree.update(model.transfers, search: model.search, filter: model.filter)
            if generation != model.tree.generation {
                generation = model.tree.generation
                filtering = !model.search.isEmpty || model.filter != .all
                restoring = true
                outline.reloadData()
                var restoredSelection: TorrentTreeNode?
                // Only descend into persisted expanded branches. Filter results reveal their location.
                for node in model.tree.roots { restore(node, outline: outline, reveal: filtering, depth: 0) }
                if let selectedID {
                    for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? TorrentTreeNode)?.id == selectedID { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); restoredSelection = outline.item(atRow: row) as? TorrentTreeNode; break }
                }
                restoring = false
                let capturedGeneration = generation
                if model.selection !== restoredSelection {
                    Task { @MainActor [weak self] in
                        guard let self, self.canInteract, self.generation == capturedGeneration else { return }
                        model.selection = restoredSelection
                    }
                }
            } else if outline.window?.isVisible ?? false {
                let rows = outline.rows(in: outline.visibleRect)
                if rows.location != NSNotFound && rows.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<min(outline.numberOfRows, rows.location + rows.length)), columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
                }
            }
        }
        private func restore(_ node: TorrentTreeNode, outline: NSOutlineView, reveal: Bool, depth: Int) {
            // Search opens ancestors but never automatically expands thousands of file leaves.
            let autoExpand: Bool
            switch node.kind { case .volume, .resolving: autoExpand = true; case .folder: autoExpand = node.fileIndices == nil; default: autoExpand = false }
            if node.expandable && (expanded.contains(node.id) || (reveal && autoExpand) || (!model.uiState.hasSavedExpansion && depth == 0)) {
                outline.expandItem(node)
                for child in node.children { restore(child, outline: outline, reveal: reveal, depth: depth + 1) }
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard belongsToActiveProfile else { return 0 }
            return (item as? TorrentTreeNode)?.children.count ?? model.tree.roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? TorrentTreeNode)?.children[index] ?? model.tree.roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { belongsToActiveProfile && ((item as? TorrentTreeNode)?.expandable ?? false) }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard belongsToActiveProfile, let node = item as? TorrentTreeNode, let column = tableColumn else { return nil }
            let cellID = column.identifier
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView(); cell.identifier = cellID
                let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; text.lineBreakMode = .byTruncatingMiddle; text.font = .systemFont(ofSize: NSFont.systemFontSize)
                cell.addSubview(text); cell.textField = text
                if cellID.rawValue == "name" {
                    let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
                    NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)])
                } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true; text.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
                NSLayoutConstraint.activate([text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let metrics = model.tree.metrics(for: node)
            let torrent: TransferSnapshot? = { if case .torrent(let id) = node.kind { return model.tree.transfers[id] }; return nil }()
            let unavailable = !node.transferIDs.isEmpty && node.transferIDs.allSatisfy { model.tree.transfers[$0]?.state == .unavailable }
            let value: String
            var tooltip: String?
            switch cellID.rawValue {
            case "name":
                value = node.name; tooltip = node.url?.path ?? node.name
                let symbol: String
                switch node.kind { case .volume: symbol = "externaldrive"; case .folder: symbol = "folder"; case .torrent: symbol = torrent?.state == .seeding ? "arrow.up.circle" : "arrow.down.circle"; case .file: symbol = "doc"; case .resolving: symbol = "network" }
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            case "size":
                if case .file(let id, let index) = node.kind, let file = model.tree.file(transferID: id, index: index) { value = byteString(file.file.length) }
                else { value = byteString(metrics.size) }
            case "progress":
                if let torrent { value = "\(torrent.state.rawValue.capitalized) · \(Int(torrent.progress * 100))%"; tooltip = torrent.error }
                else if unavailable { value = "Unavailable"; tooltip = "Reconnect the destination volume to resume its transfers." }
                else if case .file(let id, let index) = node.kind, let file = model.tree.file(transferID: id, index: index), !file.selected { value = "Skipped" }
                else { value = "\(Int(metrics.progress * 100))%" }
            case "download": value = rateString(metrics.downloadRate)
            case "upload": value = rateString(metrics.uploadRate)
            case "seeds", "peers":
                if let torrent {
                    let seeds = cellID.rawValue == "seeds", swarm = torrent.swarm
                    let connected = seeds ? swarm.connectedSeeds : swarm.connectedPeers, reported = seeds ? swarm.reportedSeeds : swarm.reportedPeers
                    let historical = reported != nil && swarm.isStale(at: .now, state: torrent.state)
                    value = "\(connected) / \(reported.map(String.init) ?? "—")\(historical ? "*" : "")"
                    let reportedTime = swarm.reportedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not reported"
                    tooltip = "\(seeds ? "Connected seeds / tracker-reported seeds" : "All connected peers, including seeds / tracker-reported total peers"). \(historical ? "Historical estimate. " : "")Reported: \(reportedTime). Tracker: \(swarm.tracker ?? "Unknown")"
                } else { value = "" }
            default: value = ""
            }
            cell.textField?.stringValue = value
            cell.textField?.textColor = torrent?.state == .failed || unavailable ? .systemOrange : .labelColor
            cell.toolTip = tooltip
            cell.setAccessibilityLabel("\(column.title): \(value)")
            cell.setAccessibilityHelp(tooltip)
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard canInteract, let outline, !restoring else { return }
            model.selection = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? TorrentTreeNode : nil
            selectedID = model.selection?.id
            if !filtering && persistsState { model.uiState.selectedNodeID = selectedID }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { rememberExpansion(notification, expanding: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { rememberExpansion(notification, expanding: false) }
        private func rememberExpansion(_ notification: Notification, expanding: Bool) {
            guard !restoring, !filtering, persistsState, let node = notification.userInfo?["NSObject"] as? TorrentTreeNode else { return }
            if let outline {
                for row in 0..<outline.numberOfRows {
                    if let visible = outline.item(atRow: row) as? TorrentTreeNode, outline.isItemExpanded(visible) { expanded.insert(visible.id) }
                }
            }
            if expanding { expanded.insert(node.id) } else { expanded.remove(node.id) }
            var state = model.uiState; state.expandedNodeIDs = expanded.sorted(); state.hasSavedExpansion = true; model.uiState = state
        }
        func outlineViewColumnDidMove(_ notification: Notification) { recordColumns() }
        func outlineViewColumnDidResize(_ notification: Notification) { recordColumns() }
        private func recordColumns() {
            guard let outline, !restoring, loadedState, persistsState else { return }
            var state = model.uiState
            state.columnOrder = outline.tableColumns.map { $0.identifier.rawValue }
            state.columnWidths = Dictionary(uniqueKeysWithValues: outline.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) })
            if state != model.uiState { model.uiState = state }
        }
        @objc func doubleClick(_ sender: NSOutlineView) {
            guard canInteract, sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? TorrentTreeNode else { return }
            if node.expandable { if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) } }
            else { model.revealSelection() }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard canInteract, let outline else { return }
            if outline.clickedRow >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false) }
            guard model.selection != nil else { return }
            if case .file = model.selection?.kind {
                let item = NSMenuItem(title: "Reveal in Finder", action: #selector(reveal), keyEquivalent: ""); item.target = self; menu.addItem(item); return
            }
            for (title, action) in [("Start", #selector(start)), ("Pause", #selector(pause)), ("Recheck", #selector(recheck)), ("Reveal in Finder", #selector(reveal)), ("Remove…", #selector(remove))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
                item.isEnabled = title == "Reveal in Finder" ? model.selection?.url != nil : !model.selectedIDs.isEmpty
            }
        }
        @objc func start() { guard canInteract else { return }; model.startSelection() }
        @objc func pause() { guard canInteract else { return }; model.pauseSelection() }
        @objc func recheck() { guard canInteract else { return }; model.recheckSelection() }
        @objc func reveal() { guard canInteract else { return }; model.revealSelection() }
        @objc func remove() { guard canInteract else { return }; model.confirmRemoval = true }
    }
}
