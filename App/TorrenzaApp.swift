import AppKit
import SwiftUI

@main struct TorrenzaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.applicationModel()
    var body: some Scene {
        Window("Torrenza", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 480)
                .task { delegate.model = model; model.launch() }
                .onOpenURL { model.open([$0]) }
        }
        .defaultSize(width: 1150, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Torrent…") { model.openFile() }.keyboardShortcut("o").disabled(!model.isProfileReady || model.isSwitchingProfile)
                Button("Open Magnet Link…") { model.showMagnet = true }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!model.isProfileReady || model.isSwitchingProfile || model.qbittorrentImport != nil)
                Divider()
                Button("Import from qBittorrent…", action: model.openQBittorrentImport).disabled(!model.canImportFromQBittorrent)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Torrents and Files") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(!model.isProfileReady || model.isSwitchingProfile)
            }
            CommandMenu("Profile") {
                ProfileMenuItems(model: model).disabled(!model.canSwitchProfile)
            }
            CommandMenu("Transfer") {
                Button("Start") { model.startSelection() }.disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile).keyboardShortcut("r")
                Button("Pause") { model.pauseSelection() }.disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile).keyboardShortcut("p")
                Button("Recheck") { model.recheckSelection() }.disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile)
                Divider()
                Button("Reveal in Finder") { model.revealSelection() }.disabled(model.selectedURLs.isEmpty).keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Remove…") { model.confirmRemoval = true }.disabled(model.selectedIDs.isEmpty || !model.isProfileReady || model.isSwitchingProfile).keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .toolbar) { Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option]) }
        }
        Settings { SettingsView(model: model) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Torrenza" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
