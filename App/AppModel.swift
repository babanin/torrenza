import AppKit
import Observation
import SwiftUI
import TorrentCore
import TorrentEngine
import TorrentStorage
import UniformTypeIdentifiers
import UserNotifications

@MainActor @Observable final class AppModel {
    static let profileRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Torrenza", isDirectory: true)
    private(set) var engine: TorrentEngine
    var profiles: [ProfileDescriptor] = []
    var activeProfile: ProfileDescriptor?
    var isSwitchingProfile = true
    var isProfileReady = false
    var profileName = ""
    var profileEditor: ProfileEditor?
    var profileEditorError: String?
    @ObservationIgnored private let profileStore: ProfileStore
    @ObservationIgnored let profileDefaults: UserDefaults
    #if DEBUG
    @ObservationIgnored private var profileSmokeEnabled = false
    #endif
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var transferActionTails: [String: Task<Void, Never>] = [:]
    private var pendingTransferActions: [String: Int] = [:]
    private struct FileSelectionChange {
        let token: UUID
        let indices: Set<Int>
        let selected: Bool
    }
    private var pendingFileChanges: [String: [FileSelectionChange]] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledRefresh: (source: TorrentRefreshSource, id: String, name: String)?
    private var filePickerOpen = false
    private var operationCount = 0
    private var terminating = false
    private var canChangeProfile: Bool {
        !isSwitchingProfile && !terminating && !filePickerOpen && operationCount == 0 && !isImporting && pendingImport == nil && qbittorrentImport == nil && !showMagnet && !confirmRemoval && refreshSourceEditor == nil && refreshOperation == nil
    }
    var canSwitchProfile: Bool { canChangeProfile && profileEditor == nil }

    init(root: URL = AppModel.profileRoot, defaults: UserDefaults = .standard) {
        engine = TorrentEngine(stateDirectory: root)
        profileStore = ProfileStore(root: root)
        profileDefaults = defaults
    }

    let tree = TorrentTreeModel(startupVolumeName: (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Startup Disk")
    var transfers: [TransferSnapshot] = []
    var statistics: StatisticsSnapshot?
    var settings = EngineSettings()
    var uiState = UIState() {
        didSet {
            if oldValue.appearance != uiState.appearance { applyAppearance() }
            scheduleUIStateSave()
        }
    }
    var didLoadUIState = false
    var filter: TreeFilter {
        get { let filter = TreeFilter(rawValue: uiState.filter) ?? .all; return filter == .attention ? .all : filter }
        set { uiState.filter = (newValue == .attention ? TreeFilter.all : newValue).rawValue }
    }
    var search = ""
    var searchFocusRequest = 0
    var selectedNodes: [TorrentTreeNode] = []
    var selection: TorrentTreeNode? {
        get { selectedNodes.count == 1 ? selectedNodes.first : nil }
        set { selectedNodes = newValue.map { [$0] } ?? [] }
    }
    var error: String?
    var pendingImport: ImportDraft?
    var qbittorrentImport: QBittorrentImportDraft?
    var showMagnet = false
    var magnetText = ""
    var showInspector: Bool {
        get { uiState.inspectorVisible }
        set { uiState.inspectorVisible = newValue }
    }
    var confirmRemoval = false
    var deleteFiles = false
    var refreshSourceEditor: TorrentRefreshSourceDraft?
    var refreshOperation: TorrentRefreshOperation?
    var torrentSelectionRequest: String?
    var canOperateTransfers: Bool { isProfileReady && !isSwitchingProfile && !terminating && refreshOperation == nil && refreshSourceEditor == nil }
    var canOpenTorrentURL: Bool { isProfileReady && canChangeProfile && profileEditor == nil }
    var refreshSelection: TransferSnapshot? {
        guard selectedNodes.count == 1, case .torrent(let id) = selectedNodes[0].kind else { return nil }
        return transfers.first { $0.id == id && $0.state != .resolving }
    }
    var canRefreshSelection: Bool { canOpenTorrentURL && refreshSelection != nil }
    var notificationsEnabled: Bool {
        get { uiState.notificationsEnabled }
        set { uiState.notificationsEnabled = newValue }
    }
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var previousStates: [String: TransferState] = [:]
    @ObservationIgnored private var importQueue: [URL] = []
    private var isImporting = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var uiSaveTask: Task<Void, Never>?

    var selectedTransfer: TransferSnapshot? {
        let ids = selectedNodes.reduce(into: Set<String>()) { $0.formUnion($1.transferIDs) }
        let selected = transfers.filter { ids.contains($0.id) }
        return selected.count == 1 ? selected.first : nil
    }
    var selectedIDs: Set<String> {
        let ids = selectedNodes.reduce(into: Set<String>()) { ids, node in
            if case .file = node.kind { return }
            ids.formUnion(node.transferIDs)
        }
        return ids.intersection(transfers.lazy.filter { $0.state != .resolving }.map(\.id))
    }
    var selectedURLs: [URL] {
        var seen = Set<URL>()
        return selectedNodes.compactMap(\.url).filter { seen.insert($0).inserted }
    }
    var activeCount: Int { transfers.filter { [.downloading, .seeding].contains($0.state) }.count }

    static func applicationModel() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--refresh-fetch-smoke") || ProcessInfo.processInfo.arguments.contains("--refresh-rutracker-smoke") {
            let id = UUID().uuidString
            return AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Refresh-Fetch/\(id)", isDirectory: true), defaults: UserDefaults(suiteName: "dev.torrenza.refresh-fetch-smoke.\(id)")!)
        }
        if ProcessInfo.processInfo.arguments.contains("--profile-smoke") {
            let id = UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Profile-Smoke/\(id)", isDirectory: true)
            let model = AppModel(root: root, defaults: UserDefaults(suiteName: "dev.torrenza.profile-smoke.\(id)")!)
            model.profileSmokeEnabled = true
            return model
        }
        #endif
        return AppModel()
    }

    func launch() {
        guard !started else { return }; started = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--refresh-rutracker-smoke") {
            Task { await runRuTrackerFetchSmoke() }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--refresh-fetch-smoke") {
            Task { await runRefreshFetchSmoke() }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            isSwitchingProfile = false; isProfileReady = true
            installDebugFixture()
            return
        }
        #endif
        profileTask = Task {
            defer { isSwitchingProfile = false; processNextImport() }
            do {
                profiles = try await profileStore.list()
                let lastID = profileDefaults.string(forKey: "activeProfileID")
                guard let profile = profiles.first(where: { $0.id == lastID }) ?? profiles.first(where: { $0.id == "default" }) else { return }
                try await activate(profile)
            } catch { self.error = "Could not open profile: \(error.localizedDescription)" }
        }
        #if DEBUG
        if profileSmokeEnabled {
            Task { await profileTask?.value; await runProfileSmoke() }
        }
        #endif
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.perform { await $0.suspend() } }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.perform { await $0.resume() } }
        })
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            lifecycleObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.perform { await $0.volumesChanged() } }
            })
        }
    }
    // Bind each asynchronous action to the engine that was active when it began.
    // A profile transition waits for these actions instead of redirecting their results.
    private func perform(_ operation: @escaping @MainActor (TorrentEngine) async -> Void) {
        guard isProfileReady, !isSwitchingProfile, !terminating else { return }
        let target = engine, id = UUID()
        operationCount += 1
        operations[id] = Task {
            defer { operations[id] = nil; operationCount -= 1 }
            await operation(target)
        }
    }

    private func observe(_ target: TorrentEngine) {
        observation?.cancel()
        observation = Task {
            for await _ in await target.snapshots() {
                guard !Task.isCancelled, engine === target else { break }
                let sessionStatistics = await target.statistics()
                // Read after the suspension so an older stream event cannot undo a completed file action.
                let updates = await target.currentSnapshots()
                guard !Task.isCancelled, engine === target else { break }
                for transfer in updates {
                    if notificationsEnabled, let old = previousStates[transfer.id], [.downloading, .checking].contains(old), [.seeding, .completed].contains(transfer.state) {
                        notifyCompletion(transfer)
                    }
                }
                previousStates = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0.state) })
                transfers = updates; statistics = sessionStatistics
                updateSleepActivity()
            }
        }
    }

    private func activate(_ profile: ProfileDescriptor) async throws {
        let candidate = TorrentEngine(stateDirectory: profile.directory)
        try await candidate.prepareForActivation()
        // Validate interface preferences before stopping the current profile.
        let savedUI = try await candidate.loadUIState()
        var nextUI = try savedUI.map { try JSONDecoder().decode(UIState.self, from: $0) } ?? UIState()
        var legacyKeys: [String] = []
        if savedUI == nil, profile.id == "default" {
            let migration = migrateLegacyUIState(); nextUI = migration.state; legacyKeys = migration.keys
        }
        let previous = engine
        let hadPrevious = isProfileReady
        uiSaveTask?.cancel()
        await uiSaveTask?.value
        if hadPrevious {
            try await previous.saveUIState(JSONEncoder().encode(uiState))
            observation?.cancel()
            do { try await previous.shutdownForProfileSwitch() }
            catch {
                await previous.resumeAfterFailedProfileSwitch()
                observe(previous)
                throw error
            }
        }
        do {
            try await candidate.activatePreparedProfile()
            try await candidate.saveUIState(JSONEncoder().encode(nextUI))
        } catch {
            let activationError = error
            await candidate.shutdown()
            if hadPrevious, let activeProfile {
                // A completed shutdown closes disks and ends the session. Reopen the
                // prior database with a fresh engine rather than reviving closed actors.
                let rollback = TorrentEngine(stateDirectory: activeProfile.directory)
                do {
                    try await rollback.prepareForActivation()
                    try await rollback.activatePreparedProfile()
                    engine = rollback
                    statistics = await rollback.statistics()
                    observe(rollback)
                } catch {
                    isProfileReady = false; didLoadUIState = false
                    transfers = []; statistics = nil; selection = nil
                    updateSleepActivity()
                    throw TorrentError.storage("Could not open \(profile.name): \(activationError.localizedDescription). Could not reopen \(activeProfile.name): \(error.localizedDescription). Both profile databases were preserved.")
                }
            }
            throw activationError
        }
        didLoadUIState = false
        engine = candidate; activeProfile = profile
        selection = nil; search = ""; previousStates = [:]; transfers = []; statistics = await candidate.statistics()
        tree.update([], search: "", filter: .all)
        settings = await candidate.settings()
        uiState = nextUI
        if uiState.filter == TreeFilter.attention.rawValue { uiState.filter = TreeFilter.all.rawValue }
        didLoadUIState = true; isProfileReady = true
        profileDefaults.set(profile.id, forKey: "activeProfileID")
        for key in legacyKeys { profileDefaults.removeObject(forKey: key) }
        updateSleepActivity()
        observe(candidate)
    }

    func switchProfile(_ profile: ProfileDescriptor) {
        guard canSwitchProfile, activeProfile?.id != profile.id || !isProfileReady else { return }
        isSwitchingProfile = true
        profileTask = Task {
            defer { isSwitchingProfile = false; processNextImport() }
            do { try await activate(profile) }
            catch { self.error = "Could not switch to \(profile.name): \(error.localizedDescription)" }
        }
    }
    func beginCreateProfile() {
        guard canSwitchProfile else { return }
        profileName = ""; profileEditorError = nil; profileEditor = .create
    }
    func beginRenameProfile() {
        guard canSwitchProfile, let activeProfile else { return }
        profileName = activeProfile.name; profileEditorError = nil; profileEditor = .rename
    }
    func submitProfile() {
        guard canChangeProfile, let editor = profileEditor else { return }
        isSwitchingProfile = true; profileEditorError = nil
        let name = profileName
        profileTask = Task {
            defer { isSwitchingProfile = false; processNextImport() }
            do {
                switch editor {
                case .create:
                    let created = try await profileStore.create(name: name)
                    profiles = try await profileStore.list()
                    // Keep a created profile available even if its first activation fails.
                    profileEditor = nil
                    try await activate(created)
                case .rename:
                    guard let activeProfile else { return }
                    self.activeProfile = try await profileStore.rename(profile: activeProfile, name: name)
                    profiles = try await profileStore.list()
                    profileEditor = nil
                }
            } catch {
                if profileEditor != nil { profileEditorError = error.localizedDescription }
                else { self.error = error.localizedDescription }
            }
        }
    }

    func saveSettings() {
        let value = settings
        perform { target in await target.updateSettings(value); self.settings = await target.settings(); self.updateSleepActivity() }
    }
    func enableNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        if enabled {
            let profileID = activeProfile?.id
            Task {
                do {
                    let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if !allowed, activeProfile?.id == profileID { notificationsEnabled = false }
                }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func notifyCompletion(_ transfer: TransferSnapshot) {
        let content = UNMutableNotificationContent(); content.title = "Download Complete"; content.body = transfer.name
        let request = UNNotificationRequest(identifier: "\(activeProfile?.id ?? "default"):\(transfer.id)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
    private func updateSleepActivity() {
        let prevent = settings.preventIdleSleep && transfers.contains { $0.state == .downloading }
        if prevent && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiatedAllowingIdleSystemSleep], reason: "Downloading torrents")
        } else if !prevent, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil
        }
    }
    func openFile() {
        guard isProfileReady, !isSwitchingProfile, !terminating, !filePickerOpen, profileEditor == nil, qbittorrentImport == nil, refreshSourceEditor == nil, refreshOperation == nil else { return }
        filePickerOpen = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.torrent]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.directoryURL = uiState.lastTorrentDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.filePickerOpen = false
                if response == .OK, !self.terminating {
                    self.uiState.lastTorrentDirectory = panel.urls.first?.deletingLastPathComponent()
                    self.open(panel.urls)
                }
            }
        }
    }
    func chooseDestination(for draft: ImportDraft) {
        guard pendingImport === draft, isProfileReady, !isSwitchingProfile, !terminating, !filePickerOpen, !draft.isAdding else { return }
        filePickerOpen = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Choose Destination"
        panel.directoryURL = draft.destination ?? uiState.lastDestinationDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { [weak self, weak draft] response in
            Task { @MainActor in
                guard let self else { return }
                self.filePickerOpen = false
                guard response == .OK, !self.terminating, let draft, self.pendingImport === draft, let directory = panel.url else { return }
                draft.destination = directory
                self.uiState.lastDestinationDirectory = directory
            }
        }
    }
    func open(_ urls: [URL]) {
        let supported = urls.filter { $0.isFileURL || $0.scheme?.lowercased() == "magnet" }
        if supported.count != urls.count { error = "Open a local .torrent file or a magnet link." }
        importQueue += supported; processNextImport()
    }
    func submitMagnet() {
        guard refreshOperation == nil, refreshSourceEditor == nil, !terminating else { return }
        guard let url = URL(string: magnetText.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "magnet" else { error = "Enter a valid magnet link."; return }
        showMagnet = false; magnetText = ""; open([url])
    }
    private func processNextImport() {
        guard isProfileReady, !isSwitchingProfile, !terminating, !isImporting, profileEditor == nil, pendingImport == nil, qbittorrentImport == nil, refreshSourceEditor == nil, refreshOperation == nil, !importQueue.isEmpty else { return }
        let url = importQueue.removeFirst(); isImporting = true
        let engine = self.engine
        importTask = Task {
            defer { isImporting = false; if pendingImport == nil { processNextImport() } }
            do {
                let meta: TorrentMetainfo
                if url.scheme?.lowercased() == "magnet" { meta = try await engine.resolve(magnet: url) }
                else {
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw TorrentError.invalidMetainfo("Torrent metadata exceeds the 16 MiB limit.") }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    meta = try await engine.inspect(torrent: data)
                }
                try Task.checkCancellation()
                guard !terminating else { return }
                pendingImport = ImportDraft(metainfo: meta, ratio: settings.defaultSeedRatio)
            } catch { self.error = error.localizedDescription }
        }
    }
    func finishImport(_ draft: ImportDraft) {
        guard pendingImport === draft, isProfileReady, !isSwitchingProfile, !terminating, !draft.isAdding, let destination = draft.destination else { return }
        draft.error = nil
        draft.isAdding = true
        perform { [self] engine in
            defer { draft.isAdding = false }
            do {
                let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                var metainfo = draft.metainfo
                if !draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let sourceURL = URL(string: draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TorrentError.invalidMetainfo("Enter a valid torrent source URL.") }
                    metainfo.refreshSource = try TorrentRefreshSource(url: sourceURL)
                }
                _ = try await engine.add(metainfo: metainfo, destination: destination, selectedFiles: draft.selectedFiles, seedRatio: draft.unlimitedSeed ? nil : draft.ratio, allowExisting: draft.allowExisting, startPaused: draft.selectedFiles.isEmpty)
                pendingImport = nil
            } catch { draft.error = error.localizedDescription }
        }
    }
    func profileEditorDismissed() { processNextImport() }
    func importDismissed() { pendingImport = nil; processNextImport() }
    var canImportFromQBittorrent: Bool { isProfileReady && canSwitchProfile }
    func openQBittorrentImport() {
        guard canImportFromQBittorrent else { return }
        qbittorrentImport = QBittorrentImportDraft(existingIDs: Set(transfers.map(\.id)))
    }
    func finishQBittorrentImport(_ draft: QBittorrentImportDraft) {
        guard qbittorrentImport === draft, isProfileReady, !isSwitchingProfile, !terminating, !draft.isImporting, !draft.isScanning, !draft.selection.isEmpty else { return }
        draft.isImporting = true
        let ratio = settings.defaultSeedRatio
        perform { engine in await draft.importSelected(engine: engine, defaultSeedRatio: ratio) }
    }
    func closeQBittorrentImport() {
        guard let draft = qbittorrentImport, !draft.isImporting, !draft.isScanning else { return }
        draft.requestClose()
        draft.releaseAccess()
        qbittorrentImport = nil
    }
    func qbittorrentImportDismissed() { processNextImport() }
    var actionTargets: [String: TransferActionTarget] {
        TorrentTreeActions.resolve(selectedNodes, transfers: transfers)
    }
    var canActOnSelection: Bool { canOperateTransfers && !actionTargets.isEmpty }
    private var selectionHasFiles: Bool { actionTargets.values.contains { if case .files = $0 { return true }; return false } }
    private var selectionHasTorrents: Bool { actionTargets.values.contains(.torrent) }
    var startSelectionTitle: String { selectionHasFiles ? (selectionHasTorrents ? "Start Transfers / Download Files" : "Download") : "Start" }
    var pauseSelectionTitle: String { selectionHasFiles ? (selectionHasTorrents ? "Pause Transfers / Stop Downloading Files" : "Stop Downloading") : "Pause" }
    var startSelectionHelp: String { selectionHasFiles ? "Enable selected files and all files in selected torrent folders, including search-hidden files; start all enabled files. Whole-torrent selections start those transfers." : "Start selected transfers" }
    var pauseSelectionHelp: String { selectionHasFiles ? "Disable selected files and all files in selected torrent folders, including search-hidden files. Keep downloaded data. Whole-torrent selections pause those transfers." : "Pause selected transfers" }
    var canRecheckSelection: Bool { canOperateTransfers && !selectedIDs.isEmpty && selectedIDs.allSatisfy { pendingTransferActions[$0] == nil } }
    var canRemoveSelection: Bool { canRecheckSelection }

    /// Queue at input time, before asynchronous tasks can observe stale selection snapshots.
    private func enqueueTransferAction(_ id: String, change: (indices: Set<Int>, selected: Bool)? = nil,
                                       operation: @escaping @MainActor (TorrentEngine) async throws -> Void) {
        guard canOperateTransfers else { return }
        let target = engine, token = UUID(), predecessor = transferActionTails[id]
        if let change { pendingFileChanges[id, default: []].append(.init(token: token, indices: change.indices, selected: change.selected)) }
        pendingTransferActions[id, default: 0] += 1
        operationCount += 1
        let task = Task { [self] in
            await predecessor?.value
            do { try await operation(target) }
            catch { self.error = error.localizedDescription }
            let snapshots = await target.currentSnapshots()
            if engine === target { transfers = snapshots }
            pendingFileChanges[id]?.removeAll { $0.token == token }
            if pendingFileChanges[id]?.isEmpty == true { pendingFileChanges[id] = nil }
            let remaining = (pendingTransferActions[id] ?? 1) - 1
            if remaining == 0 { pendingTransferActions[id] = nil; transferActionTails[id] = nil }
            else { pendingTransferActions[id] = remaining }
            operations[token] = nil
            operationCount -= 1
        }
        transferActionTails[id] = task
        operations[token] = task
    }
    private func applySelectionAction(start: Bool) {
        guard canActOnSelection else { return }
        for (id, target) in actionTargets {
            switch target {
            case .torrent:
                enqueueTransferAction(id) { engine in
                    if start { await engine.start(id) } else { await engine.pause(id) }
                }
            case .files(let indices): enqueueFileChange(id, indices: indices, selected: start)
            }
        }
    }
    private func enqueueFileChange(_ id: String, indices: Set<Int>, selected: Bool) {
        guard !indices.isEmpty else { return }
        enqueueTransferAction(id, change: (indices, selected)) { engine in
            try await engine.setFilesSelected(id, indices: indices, selected: selected, startWhenSelected: true)
        }
    }
    func startSelection() { applySelectionAction(start: true) }
    func pauseSelection() { applySelectionAction(start: false) }
    func recheckSelection() {
        guard canRecheckSelection else { return }
        for id in selectedIDs { enqueueTransferAction(id) { await $0.recheck(id) } }
    }
    func removeSelection() {
        guard canRemoveSelection else { return }
        let delete = deleteFiles
        for id in selectedIDs { enqueueTransferAction(id) { try await $0.remove(id, deleteFiles: delete) } }
        confirmRemoval = false; deleteFiles = false
    }
    func isFileSelected(_ index: Int, transfer: TransferSnapshot) -> Bool {
        pendingFileChanges[transfer.id]?.last(where: { $0.indices.contains(index) })?.selected
            ?? transfer.files.first(where: { $0.id == index })?.selected ?? false
    }
    func fileSelectionState(for node: TorrentTreeNode) -> NSControl.StateValue? {
        guard let target = TorrentTreeActions.fileSelection(for: node, transfers: transfers),
              let transfer = transfers.first(where: { $0.id == target.id }), !target.indices.isEmpty else { return nil }
        let selected = target.indices.filter { isFileSelected($0, transfer: transfer) }.count
        return selected == 0 ? .off : selected == target.indices.count ? .on : .mixed
    }
    func isFileSelectionPending(for node: TorrentTreeNode) -> Bool {
        node.transferIDs.contains { pendingTransferActions[$0] != nil }
    }
    func setFilesSelected(for nodes: [TorrentTreeNode], selected: Bool) {
        for (id, target) in TorrentTreeActions.resolve(nodes, transfers: transfers) {
            if case .files(let indices) = target { enqueueFileChange(id, indices: indices, selected: selected) }
        }
    }
    func revealSelection() {
        let urls = selectedURLs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func revealLibraryDatabase() {
        guard let activeProfile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([activeProfile.databaseURL])
    }
    func setFile(_ index: Int, selected: Bool, transfer: TransferSnapshot) {
        guard canOperateTransfers else { return }
        enqueueFileChange(transfer.id, indices: [index], selected: selected)
    }

    func setRatio(_ ratio: Double?, transfer: TransferSnapshot) { guard canOperateTransfers else { return }; perform { engine in await engine.setSeedRatio(transfer.id, ratio: ratio) } }
    func openTorrentURL() {
        guard canOpenTorrentURL else { return }
        refreshSourceEditor = TorrentRefreshSourceDraft(purpose: .newImport)
    }
    func openMagnet() {
        guard canOpenTorrentURL else { return }
        showMagnet = true
    }
    func beginRefreshSelection() {
        guard canRefreshSelection, let transfer = refreshSelection else { return }
        if let source = transfer.refreshSource { fetchTorrent(source: source, replacing: transfer.id, name: transfer.name) }
        else { refreshSourceEditor = TorrentRefreshSourceDraft(purpose: .transfer(id: transfer.id, refreshAfterSave: true)) }
    }
    func editRefreshSourceSelection() {
        guard canRefreshSelection, let transfer = refreshSelection else { return }
        refreshSourceEditor = TorrentRefreshSourceDraft(purpose: .transfer(id: transfer.id, refreshAfterSave: false), sourceText: transfer.refreshSource?.url.absoluteString ?? "")
    }
    func saveRefreshSource() {
        guard let draft = refreshSourceEditor, !draft.isSaving, isProfileReady, !isSwitchingProfile, !terminating else { return }
        do {
            guard let url = URL(string: draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TorrentError.invalidMetainfo("Enter a valid torrent source URL.") }
            let source = try TorrentRefreshSource(url: url)
            switch draft.purpose {
            case .newImport:
                scheduledRefresh = (source, "", "Open Torrent URL")
                refreshSourceEditor = nil
            case .transfer(let id, let refreshAfterSave):
                draft.isSaving = true
                perform { [self] target in
                    defer { draft.isSaving = false }
                    do {
                        try await target.setRefreshSource(source, for: id)
                        guard !terminating else { return }
                        if refreshAfterSave { scheduledRefresh = (source, id, transfers.first { $0.id == id }?.name ?? "Torrent") }
                        refreshSourceEditor = nil
                    } catch { draft.error = error.localizedDescription }
                }
            }
        } catch { draft.error = error.localizedDescription }
    }
    func refreshSourceEditorDismissed() {
        if let request = scheduledRefresh {
            scheduledRefresh = nil
            guard !terminating else { return }
            fetchTorrent(source: request.source, replacing: request.id.isEmpty ? nil : request.id, name: request.name)
        } else { processNextImport() }
    }
    private func fetchTorrent(source: TorrentRefreshSource, replacing id: String?, name: String) {
        guard isProfileReady, !isSwitchingProfile, !terminating, refreshOperation == nil, let profileID = activeProfile?.id else { return }
        let target = engine
        let operation = TorrentRefreshOperation(title: id == nil ? "Open Torrent URL" : "Refresh \(name)", profileID: profileID)
        operation.replacingID = id
        refreshOperation = operation
        operationCount += 1
        refreshTask = Task { [self] in
            defer { operation.isWorking = false; operationCount -= 1; refreshTask = nil }
            do {
                let bytes = try await operation.fetcher.fetch(source: source)
                try Task.checkCancellation()
                var metainfo = try await target.inspect(torrent: bytes)
                metainfo.refreshSource = source
                if let id {
                    operation.isApplying = true
                    operation.status = "Verifying and applying update…"
                    let newID: String
                    do { newID = try await target.refresh(id: id, metainfo: metainfo) }
                    catch is TorrentRefreshSelectionRequired {
                        operation.selectionMetainfo = metainfo
                        operation.status = "Your selected files are no longer in this torrent. Choose files to download."
                        return
                    }
                    operation.status = newID == id ? "Already up to date." : "Torrent refreshed."
                    if newID != id {
                        // A completed-only filter would hide newly added episodes.
                        filter = .all
                        torrentSelectionRequest = newID
                    }
                } else {
                    operation.importedMetainfo = metainfo
                    operation.status = "Torrent fetched. Continue to choose files and a destination."
                }
            } catch is CancellationError {
                operation.status = "Refresh cancelled."
            } catch TorrentError.cancelled {
                operation.status = "Refresh cancelled."
            } catch let error as URLError where error.code == .cancelled {
                operation.status = "Refresh cancelled."
            } catch {
                operation.status = "Could not refresh torrent."
                operation.error = error.localizedDescription
            }
        }
    }
    func cancelTorrentRefresh() {
        refreshOperation?.fetcher.cancel()
        refreshTask?.cancel()
    }
    func applyRefreshFileSelection() {
        guard let operation = refreshOperation, !operation.isWorking, let metainfo = operation.selectionMetainfo,
              let id = operation.replacingID, !operation.selectedFiles.isEmpty, !terminating else { return }
        let target = engine, selected = operation.selectedFiles
        operation.isWorking = true
        operation.error = nil
        operation.status = "Verifying and applying update…"
        operationCount += 1
        refreshTask = Task { [self] in
            defer { operation.isWorking = false; operationCount -= 1; refreshTask = nil }
            do {
                let newID = try await target.refresh(id: id, metainfo: metainfo, selectedFiles: selected)
                operation.selectionMetainfo = nil
                operation.status = "Torrent refreshed."
                filter = .all
                torrentSelectionRequest = newID
            } catch is CancellationError { operation.status = "Refresh cancelled." }
            catch { operation.status = "Could not refresh torrent."; operation.error = error.localizedDescription }
        }
    }
    func refreshOperationDismissed() {
        if let metainfo = finishedRemoteImport, !terminating { pendingImport = ImportDraft(metainfo: metainfo, ratio: settings.defaultSeedRatio) }
        finishedRemoteImport = nil
        processNextImport()
    }
    @ObservationIgnored private var finishedRemoteImport: TorrentMetainfo?
    func dismissTorrentRefresh() {
        guard let operation = refreshOperation, !operation.isWorking else { return }
        finishedRemoteImport = operation.importedMetainfo
        refreshOperation = nil
    }
    func signOutOfRuTracker() {
        guard canOpenTorrentURL, let profileID = activeProfile?.id else { return }
        perform { _ in await TorrentRefreshFetcher(profileID: profileID).signOut() }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        terminating = true
        let task = Task { await completeShutdown() }
        shutdownTask = task
        await task.value
    }
    private func completeShutdown() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { return }
        #endif
        terminating = true
        let center = NSWorkspace.shared.notificationCenter
        for observer in lifecycleObservers { center.removeObserver(observer) }
        lifecycleObservers = []
        await profileTask?.value
        qbittorrentImport?.requestClose()
        await qbittorrentImport?.cancelScanning()
        importTask?.cancel()
        await importTask?.value
        cancelTorrentRefresh()
        await refreshTask?.value
        for operation in Array(operations.values) { await operation.value }
        qbittorrentImport?.releaseAccess()
        observation?.cancel()
        uiSaveTask?.cancel()
        await uiSaveTask?.value
        if didLoadUIState {
            do { try await engine.saveUIState(JSONEncoder().encode(uiState)) }
            catch { NSLog("Could not save interface preferences: %@", error.localizedDescription) }
        }
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        if isProfileReady { await engine.shutdown() }
    }
    #if DEBUG
    func setDebugFileSelectionPending(_ pending: Bool, transferID: String) {
        let wasPending = pendingTransferActions[transferID] != nil
        if pending != wasPending { operationCount += pending ? 1 : -1 }
        pendingTransferActions[transferID] = pending ? 1 : nil
    }
    func setDebugFileSelection(indices: Set<Int>, selected: Bool, transferID: String) {
        pendingFileChanges[transferID, default: []].append(.init(token: UUID(), indices: indices, selected: selected))
    }
    func clearDebugFileSelection(transferID: String) { pendingFileChanges[transferID] = nil }
    func waitForProfileWork() async {
        await profileTask?.value
        for operation in Array(operations.values) { await operation.value }
    }
    #endif
    func scheduleUIStateSave() {
        guard didLoadUIState, !isSwitchingProfile, !terminating else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { return }
        #endif
        uiSaveTask?.cancel()
        let engine = self.engine, state = uiState
        uiSaveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
                try await engine.saveUIState(JSONEncoder().encode(state))
            } catch is CancellationError { }
            catch { self.error = "Could not save interface preferences: \(error.localizedDescription)" }
        }
    }
}

enum ProfileEditor: String, Identifiable {
    case create, rename
    var id: String { rawValue }
}

@MainActor @Observable final class ImportDraft: Identifiable {
    let id = UUID()
    let metainfo: TorrentMetainfo
    var destination: URL?
    var selectedFiles: Set<Int>
    var ratio: Double
    var unlimitedSeed = false
    var allowExisting = false
    var isAdding = false
    var error: String?
    var sourceText: String
    init(metainfo: TorrentMetainfo, ratio: Double) { self.metainfo = metainfo; self.ratio = ratio; selectedFiles = Set(metainfo.files.filter { !$0.isPadding }.map(\.index)); sourceText = metainfo.refreshSource?.url.absoluteString ?? "" }
}

extension UTType { static let torrent = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data) }
func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func rateString(_ rate: Double) -> String { rate > 0 ? "\(byteString(Int64(min(rate, Double(Int64.max - 1)))))/s" : "—" }
