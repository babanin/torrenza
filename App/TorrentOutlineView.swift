import AppKit
import SwiftUI
import TorrentCore
import TorrentEngine

/// Shared column definitions for initial construction, width reset, and
/// diagnostics. Identifiers are unchanged and stable.
enum TorrentColumns {
    struct Definition {
        let id: String
        let title: String
        let defaultWidth: Double
        let minimumWidth: Double
    }

    static let all: [Definition] = [
        Definition(id: "name", title: "Name", defaultWidth: 280, minimumWidth: 180),
        Definition(id: "added", title: "Added", defaultWidth: 160, minimumWidth: 65),
        Definition(id: "size", title: "Size", defaultWidth: 90, minimumWidth: 65),
        Definition(id: "progress", title: "Progress / Status", defaultWidth: 184, minimumWidth: 144),
        Definition(id: "download", title: "Download", defaultWidth: 95, minimumWidth: 65),
        Definition(id: "upload", title: "Upload", defaultWidth: 95, minimumWidth: 65),
        Definition(id: "uploaded", title: "Uploaded", defaultWidth: 110, minimumWidth: 65),
        Definition(id: "seeds", title: "Seeds", defaultWidth: 85, minimumWidth: 65),
        Definition(id: "peers", title: "Peers", defaultWidth: 85, minimumWidth: 65)
    ]

    static let defaultWidths: [String: Double] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultWidth) })
}

/// Soft native header cell: panel background, hairline bottom border, faint
/// vertical separators, and restrained pressed feedback, all painted in
/// interior drawing. Overriding `draw(withFrame:in:)` — even as a passthrough
/// — switches the enclosing scroll view into a path that offscreen captures
/// cannot rasterize, so the interior hook carries the styling instead: the
/// default bezel is covered by the opaque panel fill, native title drawing
/// runs through the inherited interior, and sort indicators keep their native
/// geometry and appearance.
final class TorrentTableHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Interior drawing is clipped to this inset frame, so the styling
        // lives inside it; the native bezel keeps the header's outer edges.
        // Overriding `draw(withFrame:in:)` — even as a passthrough — switches
        // the enclosing scroll view into a path offscreen captures cannot
        // rasterize, so the interior hook is the safe place for styling.
        let appearance = controlView.effectiveAppearance
        // One-physical-pixel strokes on the current display.
        let scale = max(1, controlView.window?.backingScaleFactor ?? 1)
        let hairline = 1 / scale
        // Opaque panel surface replaces the interior of the default bezel.
        Palette.panel.resolved(in: appearance).setFill()
        cellFrame.fill()
        // Restrained pressed feedback while a header is clicked.
        if isHighlighted {
            Palette.rowHover.resolved(in: appearance).setFill()
            cellFrame.fill()
        }
        // Vertical separators sit at the cell's leading edge, inset from the
        // top and bottom; Increase Contrast restores them to full strength.
        let border = Palette.border.resolved(in: appearance)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        border.withAlphaComponent(contrast ? 1.0 : 0.35).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 5,
                                  width: hairline,
                                  height: max(0, cellFrame.height - 10))).fill()
        // Native title drawing; sort indicators stay native.
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

struct TorrentOutlineView: NSViewRepresentable {
    @Bindable var model: AppModel
    var snapshots: [TransferSnapshot]
    var search: String
    var filter: TreeFilter
    var uiState: UIState
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.backgroundColor = .clear
        let outline = NSOutlineView()
        // Solid panel surface: the SwiftUI panel container behind this scroll
        // view provides the background, so no alternating stripes.
        outline.style = .plain
        // Custom geometry: 34-point rows for every level, sized explicitly.
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = WorkspaceMetrics.treeRowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true; outline.autosaveTableColumns = false
        // The viewport changes without rewriting column widths; users resize
        // columns manually and narrow layouts scroll horizontally. The
        // outline column must also stop auto-fitting expanded content.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.autoresizesOutlineColumn = false
        for definition in TorrentColumns.all {
            let column = NSTableColumn(identifier: .init(definition.id))
            column.title = definition.title
            column.width = definition.defaultWidth
            column.minWidth = definition.minimumWidth
            column.resizingMask = .userResizingMask
            let headerCell = TorrentTableHeaderCell(textCell: definition.title)
            headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
            column.headerCell = headerCell
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.id, ascending: definition.id == "name")
            let id = definition.id
            if id == "seeds" { column.headerToolTip = "Connected seeds / tracker-reported seeds. Estimates are not summed across trackers." }
            if id == "peers" { column.headerToolTip = "All connected peers, including seeds / tracker-reported total peers." }
            if id == "uploaded" { column.headerToolTip = "Total payload uploaded, including repeated uploads. * means since per-file tracking started; earlier uploads cannot be attributed to individual files." }
            if id == "added" { column.headerToolTip = "When the torrent was added to this profile. Locations show the newest known Added date among their visible torrents. Older entries may have no recorded date." }
            let sortHelp = id == "progress" ? "Sort by completion percentage within each folder." : ["seeds", "peers"].contains(id) ? "Sort by connected count within each folder." : "Click to sort within each folder; click again to reverse."
            column.headerToolTip = [column.headerToolTip, sortHelp].compactMap { $0 }.joined(separator: " ")
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
        var selectedNodeIDs: Set<String> = []
        var selectionRevision = 0
        var loadedState = false
        var restoring = false
        var filtering = false
        #if DEBUG
        var debugFileSelectionAction: (([TorrentTreeNode], Bool) -> Void)?
        #endif
        private let fileIcons: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 256
            return cache
        }()
        let profileID: String?
        var belongsToActiveProfile: Bool { model.activeProfile?.id == profileID }
        var canInteract: Bool { belongsToActiveProfile && model.isProfileReady && !model.isSwitchingProfile }
        /// The width-reset request this outline has already applied.
        var appliedWidthResetRequest = 0
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
            if let requested = model.torrentSelectionRequest, model.transfers.contains(where: { $0.id == requested }) {
                selectedNodeIDs = ["torrent:\(requested)"]
                model.torrentSelectionRequest = nil
                generation = -1
            }
            if model.didLoadUIState && !loadedState {
                loadedState = true; expanded = Set(model.uiState.expandedNodeIDs); selectedNodeIDs = Set(model.uiState.effectiveSelectedNodeIDs)
                // A new coordinator adopts the current reset request and
                // restores widths through the normal path above.
                appliedWidthResetRequest = model.columnWidthResetRequest
                restoring = true
                var columnOrder = model.uiState.columnOrder
                if !columnOrder.isEmpty && !columnOrder.contains("added") {
                    columnOrder.insert("added", at: columnOrder.firstIndex(of: "name").map { $0 + 1 } ?? 0)
                }
                for (position, id) in columnOrder.enumerated() where position < outline.numberOfColumns {
                    let source = outline.column(withIdentifier: .init(id))
                    if source >= 0 && source != position { outline.moveColumn(source, toColumn: position) }
                }
                for column in outline.tableColumns {
                    if let width = model.uiState.columnWidths[column.identifier.rawValue], width.isFinite { column.width = max(column.minWidth, min(1500, width)) }
                }
                restoring = false; generation = -1
            }
            // View → Reset Column Widths applies the shared defaults to the
            // live outline. Persistence callbacks are suppressed while widths
            // are assigned; the tree is not reloaded and the outline is not
            // reconstructed.
            if model.columnWidthResetRequest != appliedWidthResetRequest {
                appliedWidthResetRequest = model.columnWidthResetRequest
                let previousRestoring = restoring
                restoring = true
                for column in outline.tableColumns {
                    if let definition = TorrentColumns.all.first(where: { $0.id == column.identifier.rawValue }) {
                        column.width = definition.defaultWidth
                    }
                }
                restoring = previousRestoring
            }
            let descriptors = model.uiState.sortOrder.map { [NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)] } ?? []
            if outline.sortDescriptors != descriptors {
                restoring = true
                outline.sortDescriptors = descriptors
                restoring = false
            }
            model.tree.update(model.transfers, search: model.search, filter: model.filter, sort: model.uiState.sortOrder)
            if generation != model.tree.generation {
                generation = model.tree.generation
                filtering = !model.search.isEmpty || model.filter != .all
                restoring = true
                outline.reloadData()
                var restoredSelection: [TorrentTreeNode] = []
                // Only descend into persisted expanded branches. Filter results reveal their location.
                for node in model.tree.children(of: nil) { restore(node, outline: outline, reveal: filtering, depth: 0) }
                var selectedRows = IndexSet()
                for row in 0..<outline.numberOfRows {
                    if let node = outline.item(atRow: row) as? TorrentTreeNode, selectedNodeIDs.contains(node.id) {
                        selectedRows.insert(row); restoredSelection.append(node)
                    }
                }
                outline.selectRowIndexes(selectedRows, byExtendingSelection: false)
                // Hidden rows must not remain targets of toolbar or menu actions.
                selectedNodeIDs = Set(restoredSelection.map(\.id))
                restoring = false
                let capturedGeneration = generation
                selectionRevision += 1
                let capturedRevision = selectionRevision
                if model.selectedNodes.count != restoredSelection.count || zip(model.selectedNodes, restoredSelection).contains(where: { $0 !== $1 }) {
                    Task { @MainActor [weak self] in
                        guard let self, self.canInteract, self.generation == capturedGeneration, self.selectionRevision == capturedRevision else { return }
                        model.selectedNodes = restoredSelection
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
                for child in model.tree.children(of: node) { restore(child, outline: outline, reveal: reveal, depth: depth + 1) }
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard belongsToActiveProfile else { return 0 }
            return model.tree.children(of: item as? TorrentTreeNode).count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { model.tree.children(of: item as? TorrentTreeNode)[index] }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard canInteract, loadedState, !restoring else { return }
            let order = outlineView.sortDescriptors.first.flatMap { descriptor -> TreeSortOrder? in
                guard let key = descriptor.key, let column = TreeSortColumn(rawValue: key) else { return nil }
                return TreeSortOrder(column: column, ascending: descriptor.ascending)
            }
            guard order != model.uiState.sortOrder else { return }
            model.uiState.sortOrder = order
            refresh(model: model)
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { belongsToActiveProfile && ((item as? TorrentTreeNode)?.expandable ?? false) }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any?) -> NSTableRowView? {
            // The workspace's rounded lavender selection and quiet hover.
            TorrentTableRowView()
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard belongsToActiveProfile, let node = item as? TorrentTreeNode, let column = tableColumn else { return nil }
            let cellID = column.identifier
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView { cell = reused }
            else if cellID.rawValue == "progress" {
                let progressCell = TorrentProgressCellView(); progressCell.identifier = cellID; cell = progressCell
            }
            else {
                cell = cellID.rawValue == "name" ? TorrentNameCellView() : NSTableCellView(); cell.identifier = cellID
                let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; text.lineBreakMode = .byTruncatingMiddle; text.font = .systemFont(ofSize: NSFont.systemFontSize)
                cell.addSubview(text); cell.textField = text
                if cellID.rawValue == "name" {
                    let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
                    NSLayoutConstraint.activate([icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)])
                    (cell as? TorrentNameCellView)?.installSelectionControl(relativeTo: icon)
                    (cell as? TorrentNameCellView)?.installBadge(relativeTo: icon)
                } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true; text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
                NSLayoutConstraint.activate([text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let metrics = model.tree.metrics(for: node)
            let torrent: TransferSnapshot? = { if case .torrent(let id) = node.kind { return model.tree.transfers[id] }; return nil }()
            let unavailable = !node.transferIDs.isEmpty && node.transferIDs.allSatisfy { model.tree.transfers[$0]?.state == .unavailable }
            let value: String
            var tooltip: String?
            let isTorrentRow: Bool
            if case .torrent = node.kind { isTorrentRow = true } else { isTorrentRow = false }
            switch cellID.rawValue {
            case "name":
                value = node.name; tooltip = node.url?.path ?? node.name
                cell.imageView?.image = icon(for: node, torrent: torrent)
                // Torrent names are one weight heavier than folder and file
                // names; every configuration sets the font so reused cells
                // cannot retain another node type's weight.
                cell.textField?.font = .systemFont(ofSize: 13, weight: isTorrentRow ? .medium : .regular)
                let badgeState = torrent?.isMultiFile == false ? torrent?.state : nil
                (cell as? TorrentNameCellView)?.setTransferState(badgeState)
                configureSelectionControl(in: cell, for: node)
                if let badgeState { tooltip = "Single-file torrent · \(badgeState.rawValue.capitalized)\n\(tooltip ?? node.name)" }
            case "size":
                if case .file(let id, let index) = node.kind, let file = model.tree.file(transferID: id, index: index) { value = byteString(file.file.length) }
                else { value = byteString(metrics.size) }
            case "added":
                if let date = model.tree.addedAt(for: node) {
                    value = date.formatted(date: .numeric, time: .shortened)
                    tooltip = "Added to this profile: \(date.formatted(date: .complete, time: .complete))"
                    if node.transferIDs.count > 1 { tooltip = "Newest known Added date among visible torrents: \(date.formatted(date: .complete, time: .complete))" }
                } else {
                    value = "—"
                    tooltip = "No Added date was recorded for this entry."
                }
            case "progress":
                if let torrent {
                    let idleWithoutFiles = [.paused, .queued, .completed].contains(torrent.state)
                        && !torrent.files.isEmpty && !torrent.files.contains { $0.selected && !$0.file.isPadding }
                    value = idleWithoutFiles ? "No files selected" : "\(torrent.state.rawValue.capitalized) · \(Int(torrent.progress * 100))%"
                    tooltip = torrent.error
                }
                else if unavailable { value = "Unavailable"; tooltip = "Reconnect the destination volume, then choose Resume or Recheck for the affected torrents." }
                else if case .file(let id, let index) = node.kind, let file = model.tree.file(transferID: id, index: index), !file.selected { value = "Skipped" }
                else { value = "\(Int(metrics.progress * 100))%" }
            case "download": value = rateString(metrics.downloadRate)
            case "upload": value = rateString(metrics.uploadRate)
            case "uploaded":
                value = byteString(metrics.uploadedBytes) + (metrics.uploadHistoryComplete ? "" : "*")
                tooltip = metrics.uploadHistoryComplete
                    ? "Total payload uploaded, including repeated uploads. Protocol overhead is excluded."
                    : "Uploaded since per-file tracking started. Earlier uploads are included in the torrent total but cannot be attributed to individual files."
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
            let textTint: NSColor = torrent?.state == .failed || unavailable ? .systemOrange : .labelColor
            if cellID.rawValue == "progress", let progressCell = cell as? TorrentProgressCellView {
                // Quiet determinate tint for paused, queued, or completed work;
                // full violet for active transfers.
                let quietTrack = Palette.accent.withAlphaComponent(0.35)
                let activeTorrent = torrent.map { [TransferState.downloading, .seeding, .checking, .resolving].contains($0.state) } ?? false
                let fraction: Double?
                let tint: NSColor
                let trackTint: NSColor
                if let torrent {
                    // Torrent rows stack status, percentage, and track; a
                    // queued torrent can legitimately sit at 100%.
                    fraction = idleWithoutFilesProgress(torrent)
                    tint = textTint
                    trackTint = activeTorrent ? Palette.accent : quietTrack
                } else if unavailable {
                    fraction = nil
                    tint = .systemOrange
                    trackTint = quietTrack
                } else if case .file(let id, let index) = node.kind,
                          let file = model.tree.file(transferID: id, index: index), !file.selected {
                    // Skipped files explain themselves without a track.
                    fraction = nil
                    tint = .secondaryLabelColor
                    trackTint = quietTrack
                } else if case .file(let id, _) = node.kind, let transfer = model.tree.transfers[id] {
                    fraction = metrics.progress
                    tint = .labelColor
                    trackTint = [TransferState.downloading, .seeding, .checking, .resolving].contains(transfer.state) ? Palette.accent : quietTrack
                } else {
                    // Aggregate volume and folder rows show percentage only.
                    fraction = nil
                    tint = .secondaryLabelColor
                    trackTint = quietTrack
                }
                progressCell.setTrackHidden(fraction == nil)
                progressCell.configure(fraction: fraction, text: value, tint: tint, trackTint: trackTint)
                progressCell.setAccessibilityLabel("Progress: \(value)")
            } else {
                cell.textField?.stringValue = value
                cell.textField?.textColor = textTint
            }
            cell.toolTip = tooltip
            cell.setAccessibilityLabel("\(column.title): \(value)")
            cell.setAccessibilityHelp(tooltip)
            return cell
        }
        /// Progress for a torrent row, or nil when the status text carries no
        /// determinate value.
        private func idleWithoutFilesProgress(_ torrent: TransferSnapshot) -> Double? {
            let idleWithoutFiles = [.paused, .queued, .completed].contains(torrent.state)
                && !torrent.files.isEmpty && !torrent.files.contains { $0.selected && !$0.file.isPadding }
            return idleWithoutFiles ? nil : torrent.progress
        }
        private func configureSelectionControl(in cell: NSTableCellView, for node: TorrentTreeNode) {
            guard let cell = cell as? TorrentNameCellView else { return }
            let state = model.fileSelectionState(for: node)
            cell.setSelectionControlVisible(state != nil)
            let checkbox = cell.selectionCheckbox
            checkbox.node = state == nil ? nil : node
            checkbox.target = self
            checkbox.action = #selector(toggleFiles(_:))
            checkbox.renderedState = state ?? .off
            checkbox.state = state ?? .off
            checkbox.isEnabled = state != nil && canInteract && model.canOperateTransfers
            checkbox.identifier = .init("file-selection:\(node.id)")
            let folder = node.kind == .folder
            let stateDescription = state == .mixed ? "Some files enabled" : state == .on ? "Enabled for download" : "Not enabled for download"
            let pending = model.isFileSelectionPending(for: node)
            let scope = folder ? "Applies to all files in this folder, including files hidden by search." : "Applies to this file."
            let help = "\(scope) Enable to start all enabled files in this torrent. Disable to stop downloading and retain existing data.\(pending ? " Updating file selection…" : "")"
            checkbox.toolTip = help
            checkbox.setAccessibilityLabel("Download \(folder ? "folder" : "file") \(node.name)")
            checkbox.setAccessibilityValueDescription(stateDescription + (pending ? ". Updating file selection" : ""))
            checkbox.setAccessibilityHelp(help)
        }
        @objc private func toggleFiles(_ checkbox: TorrentFileSelectionButton) {
            guard canInteract, model.canOperateTransfers, let node = checkbox.node else { return }
            // AppKit's mixed-state cycle may produce Off. A mixed folder always selects all.
            let selected = checkbox.renderedState != .on
            checkbox.renderedState = selected ? .on : .off
            checkbox.state = checkbox.renderedState
            #if DEBUG
            if let debugFileSelectionAction { debugFileSelectionAction([node], selected); return }
            #endif
            model.setFilesSelected(for: [node], selected: selected)
        }
        private func icon(for node: TorrentTreeNode, torrent: TransferSnapshot?) -> NSImage? {
            let symbol: String
            switch node.kind {
            case .file:
                return fileIcon(for: node)
            case .torrent:
                if torrent?.isMultiFile == false, node.url != nil { return fileIcon(for: node) }
                symbol = torrent?.state == .seeding ? "arrow.up.circle" : "arrow.down.circle"
            case .volume: symbol = "externaldrive"
            case .folder: symbol = "folder"
            case .resolving: symbol = "network"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        private func fileIcon(for node: TorrentTreeNode) -> NSImage? {
            guard let url = node.url else { return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
            let key = url.path as NSString
            if let cached = fileIcons.object(forKey: key) { return cached }
            // Ask macOS for the file's icon, including its associated application's artwork.
            // Cache it so transfer progress updates do not repeatedly query the filesystem.
            let image = NSWorkspace.shared.icon(forFile: url.path)
            fileIcons.setObject(image, forKey: key)
            return image
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard canInteract, let outline, !restoring else { return }
            selectionRevision += 1
            model.selectedNodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
            selectedNodeIDs = Set(model.selectedNodes.map(\.id))
            if !filtering && persistsState {
                var state = model.uiState
                state.selectedNodeIDs = model.selectedNodes.map(\.id)
                state.selectedNodeID = state.selectedNodeIDs?.first
                model.uiState = state
            }
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
            else if let url = node.url, !NSWorkspace.shared.open(url) {
                model.error = "Could not open \(url.lastPathComponent)."
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            updateContextMenu(menu, row: outline?.clickedRow ?? -1)
        }
        func updateContextMenu(_ menu: NSMenu, row: Int) {
            menu.removeAllItems()
            guard canInteract, outline != nil else { return }
            guard prepareContextSelection(row: row) else { return }
            func add(_ title: String, _ action: Selector, enabled: Bool, help: String? = nil) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.isEnabled = enabled; item.toolTip = help
                menu.addItem(item)
            }
            add(model.startSelectionTitle, #selector(start), enabled: model.canActOnSelection, help: model.startSelectionHelp)
            add(model.pauseSelectionTitle, #selector(pause), enabled: model.canActOnSelection, help: model.pauseSelectionHelp)
            add("Recheck", #selector(recheck), enabled: model.canRecheckSelection)
            menu.addItem(.separator())
            for entry in [("Refresh Torrent", #selector(refreshTorrent)), ("Edit Refresh Source…", #selector(editRefreshSource))] {
                add(entry.0, entry.1, enabled: model.canRefreshSelection)
            }
            menu.addItem(.separator())
            add("Reveal in Finder", #selector(reveal), enabled: !model.selectedURLs.isEmpty)
            add("Remove…", #selector(remove), enabled: model.canRemoveSelection)
        }
        @discardableResult func prepareContextSelection(row: Int) -> Bool {
            guard canInteract, let outline, row >= 0, row < outline.numberOfRows else { return false }
            if !outline.selectedRowIndexes.contains(row) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return !model.selectedNodes.isEmpty
        }
        @objc func start() { guard canInteract else { return }; model.startSelection() }
        @objc func pause() { guard canInteract else { return }; model.pauseSelection() }
        @objc func recheck() { guard canInteract else { return }; model.recheckSelection() }
        @objc func refreshTorrent() { guard canInteract else { return }; model.beginRefreshSelection() }
        @objc func editRefreshSource() { guard canInteract else { return }; model.editRefreshSourceSelection() }
        @objc func reveal() { guard canInteract else { return }; model.revealSelection() }
        @objc func remove() { guard canInteract, model.canRemoveSelection else { return }; model.confirmRemoval = true }
    }
}

/// A separate overlay preserves the native file artwork and updates independently of its cache.
private final class TorrentNameCellView: NSTableCellView {
    private let statusBadge = NSImageView()
    private var displayedState: TransferState?
    let selectionCheckbox = TorrentFileSelectionButton(checkboxWithTitle: "", target: nil, action: nil)
    private var iconLeading: NSLayoutConstraint?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colors do not resolve dynamically; re-apply the current state.
        setTransferState(displayedState)
    }

    func installSelectionControl(relativeTo icon: NSImageView) {
        selectionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        selectionCheckbox.allowsMixedState = true
        selectionCheckbox.controlSize = .small
        selectionCheckbox.setAccessibilityRole(.checkBox)
        selectionCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(selectionCheckbox)
        NSLayoutConstraint.activate([
            selectionCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            selectionCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24)
        iconLeading?.isActive = true
    }

    func setSelectionControlVisible(_ visible: Bool) {
        selectionCheckbox.isHidden = !visible
        selectionCheckbox.setAccessibilityElement(visible)
        iconLeading?.constant = visible ? 24 : 2
    }

    func installBadge(relativeTo icon: NSImageView) {
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.imageScaling = .scaleNone
        statusBadge.contentTintColor = .white
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 5
        statusBadge.layer?.borderWidth = 0.75
        statusBadge.layer?.borderColor = NSColor.white.cgColor
        statusBadge.isHidden = true
        statusBadge.setAccessibilityElement(false)
        addSubview(statusBadge)
        NSLayoutConstraint.activate([
            statusBadge.widthAnchor.constraint(equalToConstant: 10),
            statusBadge.heightAnchor.constraint(equalToConstant: 10),
            statusBadge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            statusBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2)
        ])
    }

    func setTransferState(_ state: TransferState?) {
        // Reused cells must shed the badge when they become an ordinary file or folder.
        statusBadge.isHidden = state == nil
        displayedState = state
        guard let state else { statusBadge.image = nil; statusBadge.layer?.backgroundColor = nil; return }
        let symbol: String
        let color: NSColor
        switch state {
        case .downloading: symbol = "arrow.down"; color = .systemBlue
        case .seeding: symbol = "arrow.up"; color = .systemGreen
        case .paused: symbol = "pause.fill"; color = .systemGray
        case .queued: symbol = "clock"; color = .systemGray
        case .checking: symbol = "magnifyingglass"; color = .systemPurple
        case .completed: symbol = "checkmark"; color = .systemGreen
        case .unavailable: symbol = "eject.fill"; color = .systemOrange
        case .failed: symbol = "exclamationmark"; color = .systemRed
        case .resolving: symbol = "ellipsis"; color = .systemGray
        }
        statusBadge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .bold))
        statusBadge.layer?.backgroundColor = color.resolved.cgColor
    }
}

/// Keep the stable row target and displayed state on the control, never a recycled row number.
private final class TorrentFileSelectionButton: NSButton {
    var node: TorrentTreeNode?
    var renderedState: NSControl.StateValue = .off
}
