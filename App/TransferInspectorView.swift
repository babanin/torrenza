import SwiftUI
import TorrentCore
import TorrentEngine

/// Optional transfer inspector in the workspace split. Selecting nothing,
/// one torrent, or many torrents keeps its existing semantics; opening the
/// inspector never selects or starts a torrent.
struct TransferInspector: View {
    @Bindable var model: AppModel
    @State private var tab = "Details"

    var body: some View {
        PanelContainer {
            if let transfer = model.selectedTransfer {
                VStack(alignment: .leading, spacing: 0) {
                    inspectorHeader(transfer)
                    Picker("Inspector", selection: $tab) {
                        Text("Details").tag("Details")
                        Text("Files").tag("Files")
                        Text("Trackers").tag("Trackers")
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .padding(.horizontal, WorkspaceMetrics.space3)
                    .padding(.bottom, WorkspaceMetrics.space2)
                    .accessibilityLabel("Inspector section")
                    Divider()
                    if tab == "Files" {
                        filesTab(transfer)
                    } else if tab == "Trackers" {
                        trackersTab(transfer)
                    } else {
                        detailsTab(transfer)
                    }
                }
            } else if model.selectedNodes.count > 1 {
                ContentUnavailableView("\(model.selectedNodes.count) Items Selected", systemImage: "rectangle.stack", description: Text("Use the toolbar or Transfer menu to act on the selected torrents. Select one torrent to see its details."))
            } else {
                ContentUnavailableView("Select a Torrent", systemImage: "sidebar.right", description: Text("Choose a torrent to see details and select files."))
            }
        }
    }

    private func inspectorHeader(_ transfer: TransferSnapshot) -> some View {
        let noFilesSelected = transfer.state == .paused && !transfer.files.isEmpty && !transfer.files.contains(where: \.selected)
        let status = noFilesSelected ? "No files selected" : transfer.state.rawValue.capitalized
        return VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
            Text(transfer.name)
                .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                .lineLimit(3)
                .truncationMode(.middle)
                .help(transfer.name)
            HStack(alignment: .firstTextBaseline) {
                Text(status)
                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                    .foregroundStyle(statusTint(transfer))
                Spacer(minLength: WorkspaceMetrics.space2)
                Text("\(Int(transfer.progress * 100))%")
                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.progress)
                .controlSize(.small)
                .tint(Color.torrenzaAccent)
                .accessibilityLabel("Progress \(Int(transfer.progress * 100)) percent")
        }
        .padding(.horizontal, WorkspaceMetrics.space3)
        .padding(.top, WorkspaceMetrics.space3)
        .padding(.bottom, WorkspaceMetrics.space2)
        .accessibilityElement(children: .combine)
    }

    private func statusTint(_ transfer: TransferSnapshot) -> Color {
        switch transfer.state {
        case .failed, .unavailable: .orange
        case .seeding, .completed: .green
        default: .secondary
        }
    }

    // MARK: - Details

    private func detailsTab(_ transfer: TransferSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space3) {
                GroupSurface {
                    VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                        Text("Transfer")
                            .font(.system(size: WorkspaceMetrics.metadataFontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                        labeledRow("Status", statusText(transfer))
                        labeledRow("Progress", "\(Int(transfer.progress * 100))%")
                        labeledRow("Downloaded", byteString(transfer.downloadedBytes))
                        labeledRow("Uploaded", byteString(transfer.uploadedBytes))
                        labeledRow("Ratio", transfer.downloadedBytes > 0 ? String(format: "%.2f", Double(transfer.uploadedBytes) / Double(transfer.downloadedBytes)) : "—")
                    }
                    .padding(WorkspaceMetrics.space3)
                }
                GroupSurface {
                    VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                        Text("Seeding and Destination")
                            .font(.system(size: WorkspaceMetrics.metadataFontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("Seed until", selection: Binding(get: { transfer.seedRatio ?? -1 }, set: { model.setRatio($0 < 0 ? nil : $0, transfer: transfer) })) {
                            Text("Do not seed").tag(0.0); Text("Ratio 1.0").tag(1.0); Text("Ratio 2.0").tag(2.0); Text("Unlimited").tag(-1.0)
                            if let ratio = transfer.seedRatio, ![0.0, 1.0, 2.0].contains(ratio) { Text("Ratio \(ratio.formatted())").tag(ratio) }
                        }
                        if let url = transfer.destination {
                            VStack(alignment: .leading, spacing: WorkspaceMetrics.space1) {
                                Text("Destination").foregroundStyle(.secondary)
                                Text(url.path)
                                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                    .truncationMode(.middle)
                                    .help(url.path)
                            }
                            Picker("Storage profile", selection: Binding(get: { model.settings.destinationProfiles[url.standardizedFileURL.path] ?? model.settings.storageProfile }, set: { model.settings.destinationProfiles[url.standardizedFileURL.path] = $0; model.saveSettings() })) {
                                Text("Automatic").tag(StorageProfile.automatic); Text("SSD").tag(StorageProfile.ssd); Text("HDD").tag(StorageProfile.hdd)
                            }
                        }
                    }
                    .padding(WorkspaceMetrics.space3)
                }
                if let error = transfer.error {
                    NoticeView(kind: .warning, title: "Needs Attention", message: error)
                }
            }
            .padding(WorkspaceMetrics.space3)
        }
    }

    private func statusText(_ transfer: TransferSnapshot) -> String {
        let noFiles = transfer.state == .paused && !transfer.files.isEmpty && !transfer.files.contains(where: \.selected)
        return noFiles ? "No files selected" : transfer.state.rawValue.capitalized
    }

    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: WorkspaceMetrics.space2)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.system(size: WorkspaceMetrics.metadataFontSize))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Files

    private func filesTab(_ transfer: TransferSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                ForEach(transfer.files.filter { !$0.file.isPadding }) { file in
                    Toggle(isOn: Binding(get: { model.isFileSelected(file.id, transfer: transfer) }, set: { model.setFile(file.id, selected: $0, transfer: transfer) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.file.path.joined(separator: "/"))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(file.file.path.joined(separator: "/"))
                            Text("\(byteString(file.verifiedBytes)) of \(byteString(file.file.length))")
                                .font(.system(size: WorkspaceMetrics.metadataFontSize))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("Uploaded: \(byteString(file.uploadedBytes))\(transfer.fileUploadHistoryComplete ? "" : " since tracking started")")
                                .font(.system(size: WorkspaceMetrics.metadataFontSize))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!model.canOperateTransfers)
                    .help("Enable this file and start all enabled files. Disable to stop downloading it and retain existing data.")
                }
                if !transfer.fileUploadHistoryComplete {
                    Text("Earlier uploads are included in the torrent total, but their per-file breakdown is unavailable.")
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(WorkspaceMetrics.space3)
        }
    }

    // MARK: - Trackers

    private func trackersTab(_ transfer: TransferSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                if transfer.trackers.isEmpty {
                    Text("No trackers supplied.").foregroundStyle(.secondary)
                }
                ForEach(transfer.trackers, id: \.self) { tracker in
                    Text(tracker)
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(WorkspaceMetrics.space3)
        }
    }
}
