import AppKit
import SwiftUI
import TorrentCore
import TorrentEngine
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        workspace
            .overlay {
                if model.isSwitchingProfile {
                    ProgressView("Opening profile…")
                        .padding(WorkspaceMetrics.space6)
                        .background(reduceTransparency ? AnyShapeStyle(Color.torrenzaPanel) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius + 4, style: .continuous))
                        .accessibilityLabel("Opening profile")
                }
            }
            .toolbar(removing: .title)
            .toolbar { toolbarContent }
            .navigationTitle("Torrenza")
            .dropDestination(for: URL.self) { urls, _ in
                guard model.isProfileReady, !model.isSwitchingProfile else { return false }
                model.open(urls); return !urls.isEmpty
            }
            .sheet(item: $model.profileEditor, onDismiss: model.profileEditorDismissed) { editor in ProfileEditorView(model: model, editor: editor) }
            .sheet(item: $model.pendingImport, onDismiss: model.importDismissed) { draft in AddTorrentView(model: model, draft: draft) }
            .sheet(item: $model.qbittorrentImport, onDismiss: model.qbittorrentImportDismissed) { draft in QBittorrentImportView(model: model, draft: draft) }
            .sheet(isPresented: $model.showMagnet) { magnetSheet }
            .sheet(isPresented: $model.confirmRemoval) { removalSheet }
            .sheet(item: $model.refreshSourceEditor, onDismiss: model.refreshSourceEditorDismissed) { draft in TorrentRefreshSourceView(model: model, draft: draft) }
            .sheet(item: $model.refreshOperation, onDismiss: model.refreshOperationDismissed) { operation in TorrentRefreshProgressView(model: model, operation: operation) }
            .alert("Torrenza", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Workspace

    private var workspace: some View {
        // The split and its hosted panes live for the app's lifetime; the
        // coordinator refreshes its layout token whenever a new profile's
        // layout arrives, so pane-width reports always target the active
        // profile and restoration cannot cross-contaminate saved geometry.
        let layoutToken = model.currentLayoutToken
        return VStack(spacing: WorkspaceMetrics.panelSpacing) {
            WorkspaceSplitView(
                model: model,
                sidebarVisible: model.isSidebarVisible,
                sidebarWidth: model.sidebarWidth,
                inspectorVisible: model.showInspector,
                inspectorWidth: model.inspectorWidth,
                layoutToken: layoutToken,
                sidebar: {
                    LibrarySidebarView(model: model)
                },
                central: {
                    centralPanel
                        .disabled(!model.isProfileReady || model.isSwitchingProfile)
                },
                inspector: {
                    TransferInspector(model: model)
                        .disabled(!model.canOperateTransfers)
                }
            )
            // No split-level identity: the outline inside carries its own
            // profile identity, pane-width restores flow through the
            // coordinator's external sync, and rebuilding the split on
            // profile activation leaves AppKit key-state walking a freed view.
            StatusShelfView(model: model)
        }
        .padding(WorkspaceMetrics.outerPadding)
        .background(Color.torrenzaCanvas.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centralPanel: some View {
        PanelContainer {
            VStack(spacing: 0) {
                CentralPanelHeader(model: model, visibleCount: model.visibleTorrentCount)
                Divider().overlay(Color.torrenzaBorder)
                centralContent
            }
        }
    }

    @ViewBuilder private var centralContent: some View {
        if model.transfers.isEmpty {
            EmptyLibraryView(
                openFile: model.openFile,
                openURL: model.openTorrentURL,
                openMagnet: model.openMagnet,
                importQBittorrent: model.openQBittorrentImport
            )
        } else if model.visibleTorrentCount == 0 {
            if !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptySearchResultsView(query: model.search) { model.search = "" }
            } else {
                EmptyFilterView(filter: model.filter) { model.filter = .all }
            }
        } else {
            TorrentOutlineView(model: model, snapshots: model.transfers, search: model.search, filter: model.filter, uiState: model.uiState)
                .id(model.activeProfile?.id)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(id: "sidebar-toggle", placement: .navigation) {
            Button {
                model.isSidebarVisible.toggle()
            } label: {
                Label(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading")
            }
            .help(model.isSidebarVisible ? "Hide the library sidebar" : "Show the library sidebar")
            .disabled(!model.isProfileReady || model.isSwitchingProfile)
        }
        ToolbarItem(id: "profile-title", placement: .principal) {
            Menu {
                ProfileMenuItems(model: model)
            } label: {
                HStack(spacing: WorkspaceMetrics.space1) {
                    Text("Torrenza").font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                    Text("·").foregroundStyle(.tertiary)
                    Text(model.activeProfile?.name ?? "Choose Profile")
                        .font(.system(size: WorkspaceMetrics.contentFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 240)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Switch profile: \(model.activeProfile?.name ?? "None")")
            .accessibilityLabel("Profile: \(model.activeProfile?.name ?? "None")")
            .disabled(!model.canSwitchProfile)
        }
        ToolbarItem(id: "add-transfer", placement: .primaryAction) {
            Menu {
                Button("Open Torrent…", action: model.openFile)
                Button("Open Torrent URL…", action: model.openTorrentURL).disabled(!model.canOpenTorrentURL)
                Button("Open Magnet Link…", action: model.openMagnet).disabled(!model.canOpenTorrentURL)
                Divider()
                Button("Import from qBittorrent…", action: model.openQBittorrentImport)
                    .disabled(!model.canImportFromQBittorrent)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .tint(Color.torrenzaAccent)
            .help("Add a torrent or magnet link")
            .disabled(!model.canOpenTorrentURL)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.startSelection) { Label(model.startSelectionTitle, systemImage: "play") }
                .help(model.startSelectionHelp)
                .disabled(!model.canActOnSelection)
            Button(action: model.pauseSelection) { Label(model.pauseSelectionTitle, systemImage: "pause") }
                .help(model.pauseSelectionHelp)
                .disabled(!model.canActOnSelection)
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help(model.showInspector ? "Hide inspector" : "Show inspector")
        }
    }

    // MARK: - Small sheets

    private var magnetSheet: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space4) {
            SheetHeader(title: "Open Magnet Link", subtitle: "Torrent metadata is retrieved before you choose files and a destination.", systemImage: "link")
            TextField("magnet:?xt=urn:btih:…", text: $model.magnetText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.submitMagnet)
                .accessibilityLabel("Magnet link")
            SheetFooter {
                EmptyView()
            } actions: {
                Button("Cancel") { model.showMagnet = false }.keyboardShortcut(.cancelAction)
                Button("Continue", action: model.submitMagnet).keyboardShortcut(.defaultAction).disabled(model.magnetText.isEmpty)
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(width: 480)
    }

    private var removalSheet: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space4) {
            SheetHeader(title: "Remove \(model.selectedIDs.count) transfer\(model.selectedIDs.count == 1 ? "" : "s")?", subtitle: "The selected transfers will be removed from Torrenza.", systemImage: "trash")
            Toggle("Also delete downloaded files", isOn: $model.deleteFiles)
            if model.deleteFiles {
                Text("Downloaded files for these transfers will be permanently deleted.")
                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                    .foregroundStyle(.red)
            }
            SheetFooter {
                EmptyView()
            } actions: {
                Button("Cancel") { model.confirmRemoval = false; model.deleteFiles = false }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive, action: model.removeSelection)
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(width: 440)
    }
}

struct ProfileMenuItems: View {
    @Bindable var model: AppModel
    var body: some View {
        ForEach(model.profiles) { profile in
            Button { model.switchProfile(profile) } label: {
                if profile.id == model.activeProfile?.id {
                    Label(profile.name, systemImage: "checkmark")
                } else {
                    Text(profile.name)
                }
            }
        }
        Divider()
        Button("New Profile…", action: model.beginCreateProfile)
        Button("Rename Profile…", action: model.beginRenameProfile)
            .disabled(model.activeProfile == nil)
    }
}

private struct ProfileEditorView: View {
    @Bindable var model: AppModel
    let editor: ProfileEditor
    private var isCreating: Bool {
        if case .create = editor { return true }
        return false
    }
    private var validName: Bool {
        let name = model.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space4) {
            SheetHeader(
                title: isCreating ? "New Profile" : "Rename Profile",
                subtitle: isCreating ? "Each profile keeps its own torrents, settings, and statistics. Creating a profile switches to an empty library." : nil,
                systemImage: isCreating ? "plus.rectangle.on.rectangle" : "pencil"
            )
            TextField("Profile name", text: $model.profileName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Profile name")
                .onSubmit { if validName && !model.isSwitchingProfile { model.submitProfile() } }
            if model.profileName.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 {
                Text("Use 80 characters or fewer.")
                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                    .foregroundStyle(.red)
            }
            if let error = model.profileEditorError {
                NoticeView(kind: .error, title: "Could not save profile", message: error)
            }
            SheetFooter {
                if model.isSwitchingProfile { ProgressView().controlSize(.small) }
            } actions: {
                Button("Cancel") { model.profileEditor = nil }.keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create Profile" : "Save", action: model.submitProfile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName)
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(width: 440)
        .disabled(model.isSwitchingProfile)
        .interactiveDismissDisabled(model.isSwitchingProfile)
    }
}
