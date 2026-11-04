import SwiftUI
import TorrentCore
import TorrentEngine

/// Add Torrent sheet: summary, destination, flexible file selection, seed and
/// verification options, inline failure, and a pinned footer. An empty file
/// selection remains a valid metadata-only import.
struct AddTorrentView: View {
    @Bindable var model: AppModel
    @Bindable var draft: ImportDraft
    @Environment(\.dismiss) private var dismiss

    private var selectableFiles: [TorrentFile] { draft.metainfo.files.filter { !$0.isPadding } }
    private var selectedBytes: Int64 {
        draft.metainfo.files.filter { draft.selectedFiles.contains($0.index) }.reduce(0) { $0 + $1.length }
    }
    private var ratioInvalid: Bool {
        !draft.ratio.isFinite || draft.ratio < 0 || (!draft.selectedFiles.isEmpty && draft.allowExisting && !draft.unlimitedSeed && draft.ratio > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space3) {
            SheetHeader(
                title: draft.metainfo.name,
                subtitle: "\(selectableFiles.count) file\(selectableFiles.count == 1 ? "" : "s") · \(byteString(selectableFiles.reduce(0) { $0 + $1.length }))",
                systemImage: "arrow.down.circle"
            )
            GroupSurface {
                HStack(spacing: WorkspaceMetrics.space2) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(draft.destination?.path ?? "Choose a destination")
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(draft.destination?.path ?? "")
                    Spacer(minLength: WorkspaceMetrics.space2)
                    Button("Choose…") { model.chooseDestination(for: draft) }
                }
                .padding(WorkspaceMetrics.space3)
            }
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space1) {
                Text("Download Files")
                    .font(.system(size: WorkspaceMetrics.metadataFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                List(selectableFiles) { file in
                    Toggle(isOn: Binding(get: { draft.selectedFiles.contains(file.index) }, set: { if $0 { draft.selectedFiles.insert(file.index) } else { draft.selectedFiles.remove(file.index) } })) {
                        HStack {
                            Text(file.path.joined(separator: "/")).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(byteString(file.length)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous)
                        .strokeBorder(Color.torrenzaBorder, lineWidth: WorkspaceMetrics.hairline)
                )
                HStack(spacing: WorkspaceMetrics.space2) {
                    Button("Select All") { draft.selectedFiles = Set(selectableFiles.map(\.index)) }
                    Button("Select None") { draft.selectedFiles = [] }
                    Spacer(minLength: WorkspaceMetrics.space2)
                    Text(draft.selectedFiles.isEmpty
                         ? "Adds metadata only. Choose files in the main list when ready."
                         : byteString(selectedBytes))
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            GroupSurface {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                    TextField("Refresh source URL (optional)", text: $draft.sourceText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Refresh source URL, optional")
                    Toggle("Seed without a ratio limit", isOn: $draft.unlimitedSeed)
                    if !draft.unlimitedSeed {
                        HStack {
                            Text("Stop seeding at ratio")
                            TextField("Ratio", value: $draft.ratio, format: .number).frame(width: 70)
                        }
                    }
                    Toggle("Verify and reuse existing files", isOn: $draft.allowExisting)
                    if draft.allowExisting && !draft.selectedFiles.isEmpty {
                        Text("Existing complete files will be seeded using this choice. A ratio limit cannot be reached without downloaded-byte history; choose 0 to keep complete files stopped, or unlimited to seed them.")
                            .font(.system(size: WorkspaceMetrics.metadataFontSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(WorkspaceMetrics.space3)
            }
            if let error = draft.error {
                NoticeView(kind: .error, title: "Couldn’t add torrent", message: error)
                    .accessibilityIdentifier("torrent-import-error")
            }
            SheetFooter {
                if draft.isAdding {
                    HStack(spacing: WorkspaceMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text("Adding…").foregroundStyle(.secondary)
                    }
                }
            } actions: {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Torrent") { model.finishImport(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.torrenzaPrimaryAction)
                    .foregroundStyle(Color.torrenzaPrimaryActionText)
                    .disabled(draft.destination == nil || ratioInvalid)
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .disabled(draft.isAdding)
        .interactiveDismissDisabled(draft.isAdding)
    }
}
