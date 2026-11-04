import SwiftUI
import TorrentCore
import TorrentEngine

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }.pickerStyle(.segmented)
                Text("This visual design applies in System, Light, and Dark; no separate theme switch is needed.")
                    .font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            Section("Transfers") {
                Picker("Download preset", selection: Binding(get: { model.settings.throughputPreset }, set: { if let preset = $0 { model.settings.apply(preset) } })) {
                    Text("Custom").tag(Optional<ThroughputPreset>.none)
                    ForEach(ThroughputPreset.allCases, id: \.self) { preset in Text(preset.title).tag(Optional(preset)) }
                }
                Stepper("Active downloads: \(model.settings.maxDownloads)", value: $model.settings.maxDownloads, in: 1...8)
                Stepper("Active seeds: \(model.settings.maxSeeds)", value: $model.settings.maxSeeds, in: 0...8)
                Stepper("Maximum peers: \(model.settings.maxPeers)", value: $model.settings.maxPeers, in: EngineSettings.peerRange)
                Stepper("Requests per peer: \(model.settings.downloadRequestWindow)", value: $model.settings.downloadRequestWindow, in: EngineSettings.downloadRequestWindowRange)
                Stepper("Payload budget: \(model.settings.payloadBudget / (1024 * 1024)) MiB", value: Binding(get: { model.settings.payloadBudget / (1024 * 1024) }, set: { model.settings.payloadBudget = $0 * 1024 * 1024 }), in: 32...256)
                Text("High throughput uses up to 1,000 peers, 128 requests per peer and a 256 MiB engine payload budget. Total app memory can be higher.").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
                HStack { Text("Download limit (KiB/s)"); Spacer(); TextField("Unlimited", value: Binding(get: { model.settings.downloadLimit / 1024 }, set: { model.settings.downloadLimit = max(0, min($0, 1_000_000)) * 1024 }), format: .number).frame(width: 90) }
                HStack { Text("Upload limit (KiB/s)"); Spacer(); TextField("Unlimited", value: Binding(get: { model.settings.uploadLimit / 1024 }, set: { model.settings.uploadLimit = max(0, min($0, 1_000_000)) * 1024 }), format: .number).frame(width: 90) }
                Text("A limit of 0 means unlimited.").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
                HStack { Text("Default seed ratio"); Spacer(); TextField("Ratio", value: $model.settings.defaultSeedRatio, format: .number).frame(width: 90) }
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            Section("Storage and Energy") {
                Picker("Storage profile", selection: $model.settings.storageProfile) { Text("Automatic").tag(StorageProfile.automatic); Text("SSD").tag(StorageProfile.ssd); Text("HDD").tag(StorageProfile.hdd) }
                Text("HDD mode favors nearby writes and limits downloads to one per volume.").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
                Toggle("Prevent idle sleep while downloading", isOn: $model.settings.preventIdleSleep)
                Toggle("Notify when downloads finish", isOn: Binding(get: { model.notificationsEnabled }, set: { model.enableNotifications($0) }))
            }.disabled(!model.isProfileReady || model.isSwitchingProfile)
            if let stats = model.statistics {
                Section("Statistics") {
                    LabeledContent("Session downloaded", value: byteString(stats.current.downloadedBytes))
                    LabeledContent("Session uploaded", value: byteString(stats.current.uploadedBytes))
                    LabeledContent("Lifetime downloaded", value: byteString(stats.lifetimeDownloadedBytes))
                    LabeledContent("Lifetime uploaded", value: byteString(stats.lifetimeUploadedBytes))
                    Text("Current session started \(stats.current.startedAt.formatted(date: .abbreviated, time: .shortened)).").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
                }
            }
            Section("RuTracker") {
                Button("Sign Out of RuTracker", action: model.signOutOfRuTracker).disabled(!model.canOpenTorrentURL)
                Text("Sign in inside Torrenza when a torrent refresh requires it. Each profile keeps its own session.").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
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
                Text("Each profile has its own Torrenza.sqlite containing settings, transfers, interface preferences, and session statistics. Only the current profile runs transfers.").font(.system(size: WorkspaceMetrics.metadataFontSize)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(WorkspaceMetrics.space3)
        .frame(minWidth: 470, idealWidth: 500, minHeight: 440, idealHeight: 620)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}
