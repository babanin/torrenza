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
    private var filePickerOpen = false
    private var operationCount = 0
    private var terminating = false
    private var canChangeProfile: Bool {
        !isSwitchingProfile && !terminating && !filePickerOpen && operationCount == 0 && !isImporting && pendingImport == nil && !showMagnet && !confirmRemoval
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
    var uiState = UIState() { didSet { scheduleUIStateSave() } }
    var didLoadUIState = false
    var filter: TreeFilter {
        get { let filter = TreeFilter(rawValue: uiState.filter) ?? .all; return filter == .attention ? .all : filter }
        set { uiState.filter = (newValue == .attention ? TreeFilter.all : newValue).rawValue }
    }
    var search = ""
    var searchFocusRequest = 0
    var selection: TorrentTreeNode?
    var error: String?
    var pendingImport: ImportDraft?
    var showMagnet = false
    var magnetText = ""
    var showInspector: Bool {
        get { uiState.inspectorVisible }
        set { uiState.inspectorVisible = newValue }
    }
    var confirmRemoval = false
    var deleteFiles = false
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
        guard let selection, selection.transferIDs.count == 1, let id = selection.transferIDs.first else { return nil }
        return transfers.first { $0.id == id }
    }
    var selectedIDs: Set<String> {
        if case .file = selection?.kind { return [] }
        let ids = selection?.transferIDs ?? []
        return ids.filter { id in transfers.first(where: { $0.id == id })?.state != .resolving }
    }
    var activeCount: Int { transfers.filter { [.downloading, .seeding].contains($0.state) }.count }

    static func applicationModel() -> AppModel {
        #if DEBUG
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
            for await updates in await target.snapshots() {
                guard !Task.isCancelled, engine === target else { break }
                let sessionStatistics = await target.statistics()
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
        guard isProfileReady, !isSwitchingProfile, !terminating, !filePickerOpen, profileEditor == nil else { return }
        filePickerOpen = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.torrent]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.filePickerOpen = false
                if response == .OK, !self.terminating { self.open(panel.urls) }
            }
        }
    }
    func open(_ urls: [URL]) {
        let supported = urls.filter { $0.isFileURL || $0.scheme?.lowercased() == "magnet" }
        if supported.count != urls.count { error = "Open a local .torrent file or a magnet link." }
        importQueue += supported; processNextImport()
    }
    func submitMagnet() {
        guard let url = URL(string: magnetText.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "magnet" else { error = "Enter a valid magnet link."; return }
        showMagnet = false; magnetText = ""; open([url])
    }
    private func processNextImport() {
        guard isProfileReady, !isSwitchingProfile, !terminating, !isImporting, profileEditor == nil, pendingImport == nil, !importQueue.isEmpty else { return }
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
        guard isProfileReady, !isSwitchingProfile, !terminating, !draft.isAdding, let destination = draft.destination else { return }
        draft.isAdding = true
        perform { [self] engine in
            defer { draft.isAdding = false }
            do {
                let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                _ = try await engine.add(metainfo: draft.metainfo, destination: destination, selectedFiles: draft.selectedFiles, seedRatio: draft.unlimitedSeed ? nil : draft.ratio, allowExisting: draft.allowExisting)
                pendingImport = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    func profileEditorDismissed() { processNextImport() }
    func importDismissed() { pendingImport = nil; processNextImport() }
    func startSelection() { let ids = selectedIDs; perform { engine in for id in ids { await engine.start(id) } } }
    func pauseSelection() { let ids = selectedIDs; perform { engine in for id in ids { await engine.pause(id) } } }
    func recheckSelection() { let ids = selectedIDs; perform { engine in for id in ids { await engine.recheck(id) } } }
    func removeSelection() {
        let ids = selectedIDs, delete = deleteFiles
        perform { [self] engine in
            do { for id in ids { try await engine.remove(id, deleteFiles: delete) }; selection = nil }
            catch { self.error = error.localizedDescription }
        }
        confirmRemoval = false; deleteFiles = false
    }
    func revealSelection() { if let url = selection?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func revealLibraryDatabase() {
        guard let activeProfile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([activeProfile.databaseURL])
    }
    func setFile(_ index: Int, selected: Bool, transfer: TransferSnapshot) {
        var selectedFiles = Set(transfer.files.filter(\.selected).map(\.id))
        if selected { selectedFiles.insert(index) } else { selectedFiles.remove(index) }
        perform { [self] engine in do { try await engine.setSelectedFiles(transfer.id, selectedFiles: selectedFiles) } catch { self.error = error.localizedDescription } }
    }
    func setRatio(_ ratio: Double?, transfer: TransferSnapshot) { perform { engine in await engine.setSeedRatio(transfer.id, ratio: ratio) } }
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
        importTask?.cancel()
        await importTask?.value
        for operation in Array(operations.values) { await operation.value }
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
    init(metainfo: TorrentMetainfo, ratio: Double) { self.metainfo = metainfo; self.ratio = ratio; selectedFiles = Set(metainfo.files.filter { !$0.isPadding }.map(\.index)) }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Choose Destination"
        panel.begin { [weak self] result in if result == .OK { Task { @MainActor in self?.destination = panel.url } } }
    }
}

extension UTType { static let torrent = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data) }
func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func rateString(_ rate: Double) -> String { rate > 0 ? "\(byteString(Int64(min(rate, Double(Int64.max - 1)))))/s" : "—" }
