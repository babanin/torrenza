import AppKit
import SwiftUI
import TorrentCore
import TorrentEngine
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.transfers.isEmpty {
                    ContentUnavailableView {
                        Label("Add Your First Torrent", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Open a torrent or magnet link. Your downloads will appear in their folders.")
                    } actions: {
                        Button("Open Torrent…", action: model.openFile)
                        Button("Open Magnet Link…") { model.showMagnet = true }
                        Button("Import from qBittorrent…", action: model.openQBittorrentImport)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TorrentOutlineView(model: model, snapshots: model.transfers, search: model.search, filter: model.filter, uiState: model.uiState)
                        .id(model.activeProfile?.id)
                }
                Divider()
                HStack {
                    Text("\(model.transfers.count) transfers · \(model.activeCount) active")
                    Spacer()
                    if let stats = model.statistics {
                        Text("Session ↓ \(byteString(stats.current.downloadedBytes))  ↑ \(byteString(stats.current.uploadedBytes))")
                            .help("Lifetime downloaded: \(byteString(stats.lifetimeDownloadedBytes)). Lifetime uploaded: \(byteString(stats.lifetimeUploadedBytes)).")
                            .accessibilityLabel("Current session downloaded \(byteString(stats.current.downloadedBytes)), uploaded \(byteString(stats.current.uploadedBytes))")
                        Divider().frame(height: 12)
                    }
                    Label(rateString(model.transfers.reduce(0) { $0 + $1.downloadRate }), systemImage: "arrow.down")
                    Label(rateString(model.transfers.reduce(0) { $0 + $1.uploadRate }), systemImage: "arrow.up")
                }
                .font(.caption).monospacedDigit().lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
            }
            .disabled(!model.isProfileReady || model.isSwitchingProfile)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Torrenza")

            .inspector(isPresented: $model.showInspector) { TransferInspector(model: model).disabled(!model.isProfileReady || model.isSwitchingProfile).inspectorColumnWidth(min: 260, ideal: 320, max: 460) }
        }
        .overlay {
            if model.isSwitchingProfile {
                ProgressView("Opening profile…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Opening profile")
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(id: "profile-title", placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Torrenza").font(.headline)
                    Menu { ProfileMenuItems(model: model) } label: {
                        Text(model.activeProfile?.name ?? "Choose Profile")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Switch profile: \(model.activeProfile?.name ?? "None")")
                    .accessibilityLabel("Profile: \(model.activeProfile?.name ?? "None")")
                    .disabled(!model.canSwitchProfile)
                }
                .frame(width: 96, alignment: .leading)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "transfer-filters", placement: .principal) { toolbarFilters }
            ToolbarItem(id: "add-transfer", placement: .primaryAction) {
                Menu {
                    Button("Open Torrent…", action: model.openFile)
                    Button("Open Magnet Link…") { model.showMagnet = true }
                    Divider()
                    Button("Import from qBittorrent…", action: model.openQBittorrentImport)
                        .disabled(!model.canImportFromQBittorrent)
                } label: { Label("Add Torrent", systemImage: "plus") }
                .help("Add a torrent or magnet link")
                .disabled(!model.isProfileReady || model.isSwitchingProfile || model.qbittorrentImport != nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.startSelection) { Label("Start", systemImage: "play") }
                    .help("Start selected transfers")
                    .disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile)
                Button(action: model.pauseSelection) { Label("Pause", systemImage: "pause") }
                    .help("Pause selected transfers")
                    .disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile)
            }
            ToolbarItem(id: "transfer-search", placement: .primaryAction) {
                ToolbarSearchField(text: $model.search, focusRequest: model.searchFocusRequest)
                    .frame(width: 220, height: 28)
                    .disabled(!model.isProfileReady || model.isSwitchingProfile)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(model.showInspector ? "Hide inspector" : "Show inspector")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isProfileReady, !model.isSwitchingProfile else { return false }
            model.open(urls); return !urls.isEmpty
        }
        .sheet(item: $model.profileEditor, onDismiss: model.profileEditorDismissed) { editor in ProfileEditorView(model: model, editor: editor) }
        .sheet(item: $model.pendingImport, onDismiss: model.importDismissed) { draft in AddTorrentView(model: model, draft: draft) }
        .sheet(item: $model.qbittorrentImport, onDismiss: model.qbittorrentImportDismissed) { draft in QBittorrentImportView(model: model, draft: draft) }
        .sheet(isPresented: $model.showMagnet) { magnetSheet }
        .sheet(isPresented: $model.confirmRemoval) { removalSheet }
        .alert("Torrenza", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var toolbarFilters: some View {
        ToolbarFilterControl(selection: $model.filter)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Filter transfers")
            .disabled(!model.isProfileReady || model.isSwitchingProfile)
    }
    private var magnetSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Open Magnet Link").font(.title2).bold()
            TextField("magnet:?xt=urn:btih:…", text: $model.magnetText).textFieldStyle(.roundedBorder).onSubmit(model.submitMagnet).accessibilityLabel("Magnet link")
            Text("Torrent metadata is retrieved before you choose files and a destination.").foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { model.showMagnet = false }.keyboardShortcut(.cancelAction); Button("Continue", action: model.submitMagnet).keyboardShortcut(.defaultAction).disabled(model.magnetText.isEmpty) }
        }.padding(24).frame(width: 480)
    }
    private var removalSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remove \(model.selectedIDs.count) transfer\(model.selectedIDs.count == 1 ? "" : "s")?").font(.title2).bold()
            Text("The selected transfers will be removed from Torrenza.")
            Toggle("Also delete downloaded files", isOn: $model.deleteFiles)
            if model.deleteFiles { Text("Downloaded files for these transfers will be permanently deleted.").foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { model.confirmRemoval = false; model.deleteFiles = false }.keyboardShortcut(.cancelAction); Button("Remove", role: .destructive, action: model.removeSelection) }
        }.padding(24).frame(width: 420)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(isCreating ? "New Profile" : "Rename Profile").font(.title2).bold()
            TextField("Profile name", text: $model.profileName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Profile name")
                .onSubmit { if validName && !model.isSwitchingProfile { model.submitProfile() } }
            if isCreating {
                Text("Each profile keeps its own torrents, settings, and statistics. Creating a profile switches to an empty library.")
                    .foregroundStyle(.secondary)
            }
            if model.profileName.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 {
                Text("Use 80 characters or fewer.").font(.caption).foregroundStyle(.red)
            }
            if let error = model.profileEditorError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if model.isSwitchingProfile { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.profileEditor = nil }.keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create Profile" : "Save", action: model.submitProfile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName)
            }
        }
        .padding(24).frame(width: 420)
        .disabled(model.isSwitchingProfile)
        .interactiveDismissDisabled(model.isSwitchingProfile)
    }
}

/// AppKit's content-sized segments keep all five labels readable in the titlebar.
struct ToolbarFilterControl: NSViewRepresentable {
    @Binding var selection: TreeFilter
    private let filters: [TreeFilter] = [.all, .active, .downloading, .completed, .paused]
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, filters: filters) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: filters.map { $0 == .all ? "All" : $0.rawValue }, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small; control.segmentDistribution = .fit; control.segmentStyle = .rounded
        control.setAccessibilityLabel("Filter transfers")
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = filters.firstIndex(of: selection) ?? 0
        control.isEnabled = context.environment.isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? { nsView.intrinsicContentSize }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<TreeFilter>
        let filters: [TreeFilter]
        init(selection: Binding<TreeFilter>, filters: [TreeFilter]) { self.selection = selection; self.filters = filters }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard filters.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = filters[sender.selectedSegment]
        }
    }
}

struct AddTorrentView: View {
    @Bindable var model: AppModel
    @Bindable var draft: ImportDraft
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.metainfo.name).font(.title2).bold().lineLimit(2)
            HStack { Label(draft.destination?.path ?? "Choose a destination", systemImage: "folder").lineLimit(2).truncationMode(.middle); Spacer(); Button("Choose…") { model.chooseDestination(for: draft) } }
            List(draft.metainfo.files.filter { !$0.isPadding }) { file in
                Toggle(isOn: Binding(get: { draft.selectedFiles.contains(file.index) }, set: { if $0 { draft.selectedFiles.insert(file.index) } else { draft.selectedFiles.remove(file.index) } })) {
                    HStack { Text(file.path.joined(separator: "/")).lineLimit(1).truncationMode(.middle); Spacer(); Text(byteString(file.length)).foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 180, maxHeight: 280).border(.quaternary)
            HStack { Button("Select All") { draft.selectedFiles = Set(draft.metainfo.files.filter { !$0.isPadding }.map(\.index)) }; Button("Select None") { draft.selectedFiles = [] }; Spacer(); Text(byteString(draft.metainfo.files.filter { draft.selectedFiles.contains($0.index) }.reduce(0) { $0 + $1.length })).foregroundStyle(.secondary) }
            Form {
                Toggle("Seed without a ratio limit", isOn: $draft.unlimitedSeed)
                if !draft.unlimitedSeed { HStack { Text("Stop seeding at ratio"); TextField("Ratio", value: $draft.ratio, format: .number).frame(width: 70) } }
                Toggle("Verify and reuse existing files", isOn: $draft.allowExisting)
                if draft.allowExisting { Text("Existing complete files will be seeded using this choice. A ratio limit cannot be reached without downloaded-byte history; choose 0 to keep complete files stopped, or unlimited to seed them.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { if draft.isAdding { ProgressView().controlSize(.small); Text("Adding and verifying…").foregroundStyle(.secondary) }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Add Torrent") { model.finishImport(draft) }.keyboardShortcut(.defaultAction).disabled(draft.destination == nil || draft.selectedFiles.isEmpty || !draft.ratio.isFinite || draft.ratio < 0 || (draft.allowExisting && !draft.unlimitedSeed && draft.ratio > 0)) }
        }.padding(24).frame(width: 600).disabled(draft.isAdding).interactiveDismissDisabled(draft.isAdding)
    }
}

struct TransferInspector: View {
    @Bindable var model: AppModel
    @State private var tab = "Details"
    var body: some View {
        if let transfer = model.selectedTransfer {
            VStack(alignment: .leading, spacing: 12) {
                Text(transfer.name).font(.headline).lineLimit(3)
                Picker("Inspector", selection: $tab) { Text("Details").tag("Details"); Text("Files").tag("Files"); Text("Trackers").tag("Trackers") }.pickerStyle(.segmented)
                if tab == "Files" {
                    List(transfer.files.filter { !$0.file.isPadding }) { file in
                        Toggle(isOn: Binding(get: { file.selected }, set: { model.setFile(file.id, selected: $0, transfer: transfer) })) {
                            VStack(alignment: .leading) {
                                Text(file.file.path.joined(separator: "/")).lineLimit(2).truncationMode(.middle)
                                Text("\(byteString(file.verifiedBytes)) of \(byteString(file.file.length))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if tab == "Trackers" {
                    List(transfer.trackers, id: \.self) { tracker in Text(tracker).textSelection(.enabled).font(.caption).lineLimit(3) }
                    if transfer.trackers.isEmpty { Text("No trackers supplied.").foregroundStyle(.secondary) }
                } else {
                    Form {
                        LabeledContent("Status", value: transfer.state.rawValue.capitalized)
                        LabeledContent("Progress", value: "\(Int(transfer.progress * 100))%")
                        LabeledContent("Downloaded", value: byteString(transfer.downloadedBytes))
                        LabeledContent("Uploaded", value: byteString(transfer.uploadedBytes))
                        LabeledContent("Ratio", value: transfer.downloadedBytes > 0 ? String(format: "%.2f", Double(transfer.uploadedBytes) / Double(transfer.downloadedBytes)) : "—")
                        Picker("Seed until", selection: Binding(get: { transfer.seedRatio ?? -1 }, set: { model.setRatio($0 < 0 ? nil : $0, transfer: transfer) })) {
                            Text("Do not seed").tag(0.0); Text("Ratio 1.0").tag(1.0); Text("Ratio 2.0").tag(2.0); Text("Unlimited").tag(-1.0)
                            if let ratio = transfer.seedRatio, ![0.0, 1.0, 2.0].contains(ratio) { Text("Ratio \(ratio.formatted())").tag(ratio) }
                        }
                        if let url = transfer.destination {
                            LabeledContent("Destination") { Text(url.path).textSelection(.enabled).lineLimit(4) }
                            Picker("Storage profile", selection: Binding(get: { model.settings.destinationProfiles[url.standardizedFileURL.path] ?? model.settings.storageProfile }, set: { model.settings.destinationProfiles[url.standardizedFileURL.path] = $0; model.saveSettings() })) {
                                Text("Automatic").tag(StorageProfile.automatic); Text("SSD").tag(StorageProfile.ssd); Text("HDD").tag(StorageProfile.hdd)
                            }
                        }
                        if let error = transfer.error { Text(error).foregroundStyle(.orange) }
                    }.formStyle(.grouped)
                    Spacer()
                }
            }.padding(14)
        } else if model.selectedNodes.count > 1 {
            ContentUnavailableView("\(model.selectedNodes.count) Items Selected", systemImage: "rectangle.stack", description: Text("Use the toolbar or Transfer menu to act on the selected torrents. Select one torrent to see its details."))
        } else {
            ContentUnavailableView("Select a Torrent", systemImage: "sidebar.right", description: Text("Choose a torrent to see details and select files."))
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }.pickerStyle(.segmented)
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            Section("Transfers") {
                Stepper("Active downloads: \(model.settings.maxDownloads)", value: $model.settings.maxDownloads, in: 1...8)
                Stepper("Active seeds: \(model.settings.maxSeeds)", value: $model.settings.maxSeeds, in: 0...8)
                Stepper("Maximum peers: \(model.settings.maxPeers)", value: $model.settings.maxPeers, in: 5...200, step: 5)
                HStack { Text("Download limit (KiB/s)"); Spacer(); TextField("Unlimited", value: Binding(get: { model.settings.downloadLimit / 1024 }, set: { model.settings.downloadLimit = max(0, min($0, 1_000_000)) * 1024 }), format: .number).frame(width: 90) }
                HStack { Text("Upload limit (KiB/s)"); Spacer(); TextField("Unlimited", value: Binding(get: { model.settings.uploadLimit / 1024 }, set: { model.settings.uploadLimit = max(0, min($0, 1_000_000)) * 1024 }), format: .number).frame(width: 90) }
                Text("A limit of 0 means unlimited.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Default seed ratio"); Spacer(); TextField("Ratio", value: $model.settings.defaultSeedRatio, format: .number).frame(width: 90) }
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            Section("Storage and Energy") {
                Picker("Storage profile", selection: $model.settings.storageProfile) { Text("Automatic").tag(StorageProfile.automatic); Text("SSD").tag(StorageProfile.ssd); Text("HDD").tag(StorageProfile.hdd) }
                Text("HDD mode favors nearby writes and limits downloads to one per volume.").font(.caption).foregroundStyle(.secondary)
                Toggle("Prevent idle sleep while downloading", isOn: $model.settings.preventIdleSleep)
                Toggle("Notify when downloads finish", isOn: Binding(get: { model.notificationsEnabled }, set: { model.enableNotifications($0) }))
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            if let stats = model.statistics {
                Section("Statistics") {
                    LabeledContent("Session downloaded", value: byteString(stats.current.downloadedBytes))
                    LabeledContent("Session uploaded", value: byteString(stats.current.uploadedBytes))
                    LabeledContent("Lifetime downloaded", value: byteString(stats.lifetimeDownloadedBytes))
                    LabeledContent("Lifetime uploaded", value: byteString(stats.lifetimeUploadedBytes))
                    Text("Current session started \(stats.current.startedAt.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Library") {
                LabeledContent("Profile") {
                    Menu(model.activeProfile?.name ?? "Choose Profile") {
                        ForEach(model.profiles) { profile in
                            Button { model.switchProfile(profile) } label: {
                                if profile.id == model.activeProfile?.id { Label(profile.name, systemImage: "checkmark") }
                                else { Text(profile.name) }
                            }
                        }
                    }.disabled(!model.canSwitchProfile)
                }
                Button("Show Library Database in Finder", action: model.revealLibraryDatabase)
                    .disabled(!model.isProfileReady || model.isSwitchingProfile)
                Text("Each profile has its own Torrenza.sqlite containing settings, transfers, interface preferences, and session statistics. Only the current profile runs transfers.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 490, height: 620)
            .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}
