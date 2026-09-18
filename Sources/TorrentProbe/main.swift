import Foundation
import TorrentCore
import TorrentEngine

/// Development-only command-line harness; not embedded in the macOS application.
@main struct TorrentProbe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4, ["download", "magnet", "seed"].contains(args[0]) else {
            print("Usage: TorrentProbe download|magnet|seed TORRENT_OR_MAGNET DESTINATION STATE_DIRECTORY [SECONDS=120]")
            exit(64)
        }
        let engine = TorrentEngine(stateDirectory: URL(fileURLWithPath: args[3], isDirectory: true))
        let timeout = args.count > 4 ? Double(args[4]) ?? 120 : 120
        do {
            var settings = EngineSettings()
            settings.bootstrapNodes = [] // Local fixtures must not use public bootstrap servers.
            settings.storageProfile = .ssd
            await engine.updateSettings(settings)
            let destination = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let metainfo: TorrentMetainfo
            if args[0] == "magnet" {
                guard let url = URL(string: args[1]) else { throw TorrentError.invalidMetainfo("Invalid magnet URL") }
                metainfo = try await engine.resolve(magnet: url)
            } else {
                metainfo = try await engine.inspect(torrent: Data(contentsOf: URL(fileURLWithPath: args[1])))
            }
            let selected = Set(metainfo.files.filter { !$0.isPadding }.map(\.index))
            let id = try await engine.add(metainfo: metainfo, destination: destination, selectedFiles: selected, seedRatio: args[0] == "seed" ? nil : 0, allowExisting: args[0] == "seed")
            print("START \(id) listen=\(await engine.listenPort()) mode=\(args[0])")
            let deadline = Date().addingTimeInterval(timeout)
            var succeeded = false
            for await snapshots in await engine.snapshots() {
                guard let snapshot = snapshots.first(where: { $0.id == id }) else { continue }
                print("STATE \(snapshot.state.rawValue) bytes=\(snapshot.completedBytes)/\(snapshot.selectedBytes) down=\(snapshot.downloadedBytes) up=\(snapshot.uploadedBytes) peers=\(snapshot.swarm.connectedPeers) seeds=\(snapshot.swarm.connectedSeeds) rate=\(Int(snapshot.downloadRate)) error=\(snapshot.error ?? "none")")
                if args[0] != "seed", snapshot.completedBytes == snapshot.selectedBytes, snapshot.selectedBytes > 0 {
                    succeeded = true; break
                }
                if snapshot.state == .failed || snapshot.state == .unavailable { break }
                if Date() > deadline { succeeded = args[0] == "seed" && snapshot.uploadedBytes > 0; break }
            }
            await engine.shutdown()
            print(succeeded ? "PASS" : "FAIL")
            exit(succeeded ? 0 : 1)
        } catch {
            await engine.shutdown()
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}
