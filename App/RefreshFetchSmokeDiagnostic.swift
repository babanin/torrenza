#if DEBUG
import AppKit
import Foundation
import Network
import SwiftUI
import TorrentCore
import TorrentEngine
import TorrentStorage
import WebKit

@MainActor extension AppModel {
    /// Explicit opt-in public probe, using an ephemeral browser without user cookies.
    func runRuTrackerFetchSmoke() async {
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-RuTracker-Smoke", isDirectory: true)
        let fetcher = TorrentRefreshFetcher(profileID: "rutracker-smoke-\(UUID().uuidString)", websiteDataStore: .nonPersistent())
        var result: Result<Data, any Error>?
        var lines = ["Ephemeral WebKit session; no user credentials or profile opened.",
                     "Public fixture: https://rutracker.org/forum/viewtopic.php?t=4578927"]
        let fetchTask = Task {
            do { result = .success(try await fetcher.fetch(source: .ruTracker(topicID: "4578927", host: "rutracker.org"))) }
            catch { result = .failure(error) }
        }
        var window: NSWindow?
        var passed = false
        do {
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            let deadline = Date().addingTimeInterval(25)
            while result == nil && !fetcher.isAuthenticationRequired && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if fetcher.isAuthenticationRequired {
                lines.append("PASS: SIGN-IN/CHALLENGE REACHED")
                lines.append("Authentication callback activated the in-app login UI. Login and challenge completion were not attempted.")
                lines.append("Browser URL: \(fetcher.webView.url?.absoluteString ?? "unknown")")
                let hosting = NSHostingView(rootView: RuTrackerLoginView(fetcher: fetcher).padding(20))
                let loginWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                loginWindow.title = "Torrenza RuTracker Smoke — Ephemeral Session"
                loginWindow.contentView = hosting
                loginWindow.center()
                loginWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window = loginWindow
                try await Task.sleep(for: .milliseconds(750))
                hosting.layoutSubtreeIfNeeded()
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: report.appendingPathComponent("login-sheet.png"), options: .atomic)
                        lines.append("Login UI screenshot: login-sheet.png")
                    }
                }
                // WebKit is layer-backed; preserve its own snapshot as well as the native host.
                var browserCaptureFinished = false
                fetcher.webView.takeSnapshot(with: nil) { image, error in
                    if let image, let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                        do {
                            try png.write(to: report.appendingPathComponent("browser.png"), options: .atomic)
                            lines.append("WebKit screenshot: browser.png")
                        } catch { lines.append("WebKit screenshot write failed: \(error)") }
                    } else { lines.append("WebKit snapshot unavailable: \(error?.localizedDescription ?? "no image")") }
                    browserCaptureFinished = true
                }
                for _ in 0..<100 where !browserCaptureFinished { try await Task.sleep(for: .milliseconds(20)) }
                passed = true
            } else if let result {
                switch result {
                case .success(let data):
                    let metainfo = try MetainfoParser.parse(data)
                    lines.append("PASS: Downloaded valid public torrent metadata (\(data.count) bytes, \(metainfo.files.count) files)")
                    passed = true
                case .failure(let error):
                    let details = error as NSError
                    lines.append("RUTRACKER SMOKE FAILED: \(details.domain) code \(details.code): \(details.localizedDescription)")
                }
            } else {
                lines.append("RUTRACKER SMOKE FAILED: Neither authentication UI nor downloaded metadata reached within 25 seconds")
            }
        } catch { lines.append("RUTRACKER SMOKE FAILED: \(error)") }
        fetchTask.cancel()
        fetcher.cancel()
        await fetchTask.value
        window?.orderOut(nil)
        if !fetcher.isFetching && !fetcher.isAuthenticationRequired {
            lines.append("PASS: Fetch task completed; fetching and authentication state cleared")
        } else {
            passed = false
            lines.append("RUTRACKER SMOKE FAILED: Cancellation left active fetching state")
        }
        if passed { lines.append("RUTRACKER SMOKE PASSED") }
        do {
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: report.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        } catch { passed = false; lines.append("RUTRACKER SMOKE FAILED: Could not write report: \(error)") }
        print(lines.joined(separator: "\n"))
        exit(passed ? 0 : 1)
    }

    /// Exercises the actual app downloader using loopback fixtures and no user profile.
    func runRefreshFetchSmoke() async {
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Refresh-Fetch", isDirectory: true)
        var lines: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw RefreshSmokeFailure(message: message) }
            lines.append("PASS: " + message)
        }
        do {
            let server = try RefreshSmokeHTTPServer()
            try await server.start()
            defer { server.stop() }
            let fetcher = TorrentRefreshFetcher(profileID: "refresh-smoke-\(UUID().uuidString)", websiteDataStore: .nonPersistent())
            func fetch(_ path: String) async throws -> Data {
                try await fetcher.fetch(source: .direct(server.url(path)))
            }
            func rejected(_ path: String, by predicate: (any Error) -> Bool, _ message: String) async throws {
                do {
                    _ = try await fetch(path)
                    throw RefreshSmokeFailure(message: "Unexpected success: " + message)
                } catch {
                    try require(predicate(error), message + " (\(error.localizedDescription))")
                }
            }
            let original = try await fetch("valid")
            let metainfo = try MetainfoParser.parse(original)
            try require(metainfo.files.first?.path == ["fixture.bin"] && metainfo.totalLength == 4,
                        "Direct download returns parseable torrent metadata")
            try require(metainfo.refreshSource == .ruTracker(topicID: "1234", host: "rutracker.org"),
                        "Downloaded metadata preserves its RuTracker topic comment")
            try require(try await fetch("redirect") == original, "Allowed HTTP redirect reaches the torrent")
            try await rejected("html", by: { if case TorrentRefreshFetchError.responseIsNotTorrent = $0 { return true }; return false },
                               "HTML responses are rejected")
            let invalid = try await fetch("invalid")
            do {
                _ = try MetainfoParser.parse(invalid)
                throw RefreshSmokeFailure(message: "Invalid metadata was accepted")
            } catch let error as TorrentError {
                try require(true, "Non-HTML invalid content is rejected by the torrent parser (\(error.localizedDescription))")
            }
            try await rejected("large-header", by: { if case TorrentRefreshFetchError.tooLarge = $0 { return true }; return false },
                               "Oversized declared responses are rejected")
            try await rejected("large-stream", by: { if case TorrentRefreshFetchError.tooLarge = $0 { return true }; return false },
                               "Streaming responses without Content-Length obey the 16 MiB limit")
            try await rejected("loop", by: { if case TorrentRefreshFetchError.tooManyRedirects = $0 { return true }; return false },
                               "Redirect loops stop at the application redirect limit")
            try await rejected("invalid-redirect", by: {
                if case TorrentRefreshFetchError.invalidURL = $0 { return true }
                // Foundation may reject a non-HTTP Location before the app delegate sees it.
                return ($0 as NSError).domain == NSURLErrorDomain
            }, "Non-HTTP redirects never return payload")
            try require(try await fetch("cookie") == original && !server.receivedCookie,
                        "Direct redirect requests do not retain or forward response cookies")
            let slow = Task { try await fetch("slow") }
            for _ in 0..<100 where !server.slowRequested { try await Task.sleep(for: .milliseconds(20)) }
            try require(server.slowRequested && fetcher.isFetching, "A pending response enters cancellable fetching state")
            do {
                _ = try await fetch("valid")
                throw RefreshSmokeFailure(message: "Concurrent fetch was accepted")
            } catch TorrentRefreshFetchError.busy {
                try require(true, "Concurrent fetches are rejected")
            }
            slow.cancel()
            do {
                _ = try await slow.value
                throw RefreshSmokeFailure(message: "Cancelled response was accepted")
            } catch {
                try require(error is CancellationError || (error as? URLError)?.code == .cancelled,
                            "Task cancellation terminates a pending network request")
            }
            try require(!fetcher.isFetching && !fetcher.isAuthenticationRequired, "Cancellation clears fetching and authentication state")
            try require(try await fetch("valid") == original, "A fresh request succeeds after cancellation")
            func fetchBrowser(_ path: String) async throws -> Data {
                try await fetcher.fetchBrowserFixture(url: server.url(path))
            }
            let browserData = try await fetchBrowser("valid")
            try require(browserData == original && (try MetainfoParser.parse(browserData)).totalLength == 4,
                        "WebKit navigation converts to a download and returns valid torrent metadata")
            try require(try await fetchBrowser("attachment") == original,
                        "WebKit attachment download succeeds when the fetcher is reused")
            try require(try await fetchBrowser("redirect") == original,
                        "WebKit redirect reaches a valid torrent download")
            do {
                _ = try await fetchBrowser("large-header")
                throw RefreshSmokeFailure(message: "WebKit accepted an oversized response")
            } catch TorrentRefreshFetchError.tooLarge {
                try require(true, "WebKit rejects an oversized declared response")
            }
            var interruptedDownloadError: (any Error)?
            do { _ = try await fetchBrowser("truncated") }
            catch { interruptedDownloadError = error }
            try require(interruptedDownloadError != nil,
                        "A genuine interrupted WebKit download fails instead of returning partial metadata")
            try require(!fetcher.isFetching && !fetcher.isAuthenticationRequired,
                        "WebKit download failure clears fetching and authentication state")
            let browserLogin = Task { try await fetchBrowser("html") }
            let loginDeadline = Date().addingTimeInterval(5)
            while !fetcher.isAuthenticationRequired && Date() < loginDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let showedAuthentication = fetcher.isFetching && fetcher.isAuthenticationRequired
            browserLogin.cancel()
            var loginCancellationError: (any Error)?
            do { _ = try await browserLogin.value }
            catch { loginCancellationError = error }
            try require(showedAuthentication, "WebKit HTML response opens authentication state")
            try require(loginCancellationError is CancellationError || (loginCancellationError as? URLError)?.code == .cancelled,
                        "Cancelling WebKit authentication terminates the pending fetch")
            try require(!fetcher.isFetching && !fetcher.isAuthenticationRequired,
                        "Cancelling WebKit authentication clears fetching and authentication state")
            try require(try await fetchBrowser("valid") == original,
                        "A fresh WebKit download succeeds after authentication cancellation")
            let pipelineRoot = report.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let preferencesName = "dev.torrenza.refresh-fetch-smoke.\(UUID().uuidString)"
            guard let preferences = UserDefaults(suiteName: preferencesName) else { throw RefreshSmokeFailure(message: "Could not create isolated preferences") }
            defer { preferences.removePersistentDomain(forName: preferencesName) }
            let model = AppModel(root: pipelineRoot, defaults: preferences)
            do {
                model.activeProfile = ProfileDescriptor(id: UUID().uuidString, name: "Refresh Fixture", directory: pipelineRoot)
                model.isProfileReady = true
                model.isSwitchingProfile = false
                let destination = pipelineRoot.appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var settings = EngineSettings()
                settings.bootstrapNodes = []
                await model.engine.updateSettings(settings)
                var originalMetainfo = metainfo
                originalMetainfo.refreshSource = nil
                let oldID = try await model.engine.add(metainfo: originalMetainfo, destination: destination,
                                                       selectedFiles: [0], startPaused: true)
                let stream = await model.engine.snapshots()
                var snapshots = stream.makeAsyncIterator()
                model.transfers = await snapshots.next() ?? []
                model.selection = TorrentTreeNode(id: oldID, name: originalMetainfo.name, url: destination,
                                                  kind: .torrent(oldID), transferIDs: [oldID], expandable: false)
                model.beginRefreshSelection()
                guard let draft = model.refreshSourceEditor else { throw RefreshSmokeFailure(message: "Missing-source prompt did not open") }
                try require(model.refreshOperation == nil, "AppModel prompts for a missing refresh source before starting a fetch")
                draft.sourceText = server.url("updated").absoluteString
                model.saveRefreshSource()
                await model.waitForProfileWork()
                try require(model.refreshSourceEditor == nil && draft.error == nil,
                            "AppModel saves the entered source before dismissing its editor")
                model.refreshSourceEditorDismissed()
                let deadline = Date().addingTimeInterval(2)
                while model.refreshOperation?.isWorking == true && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                guard let operation = model.refreshOperation else { throw RefreshSmokeFailure(message: "Source-editor dismissal did not start refresh") }
                try require(!operation.isWorking && operation.error == nil && operation.status == "Torrent refreshed.",
                            "AppModel source-save-fetch-refresh pipeline completes without an error")
                let latestStream = await model.engine.snapshots()
                var latest = latestStream.makeAsyncIterator()
                let refreshed = await latest.next() ?? []
                guard let updated = refreshed.first else { throw RefreshSmokeFailure(message: "Refreshed transfer is missing") }
                try require(refreshed.count == 1 && updated.id != oldID && updated.name == metainfo.name,
                            "AppModel refresh replaces the old identity with updated metadata")
                try require(updated.state == .paused && updated.refreshSource == .direct(server.url("updated")),
                            "AppModel refresh retains paused state and the newly saved source")
                try require(model.torrentSelectionRequest == updated.id && model.error == nil,
                            "AppModel requests selection of the resulting torrent identity")
                model.dismissTorrentRefresh()
                model.refreshOperationDismissed()
                try require(model.refreshOperation == nil && model.pendingImport == nil,
                            "Dismissing a completed refresh does not open an import")
                await model.shutdown()
            } catch {
                await model.shutdown()
                throw error
            }
            lines.append("REFRESH FETCH SMOKE PASSED")
        } catch { lines.append("REFRESH FETCH SMOKE FAILED: \(error)") }
        do {
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: report.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        } catch { lines.append("REFRESH FETCH SMOKE FAILED: Could not write report: \(error)") }
        print(lines.joined(separator: "\n"))
        exit(lines.last == "REFRESH FETCH SMOKE PASSED" ? 0 : 1)
    }
}

private struct RefreshSmokeFailure: Error { let message: String }

@MainActor private final class RefreshSmokeHTTPServer {
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<Void, any Error>?
    private let payload: Data
    private(set) var receivedCookie = false
    private(set) var slowRequested = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        payload = Bencode.encode(.dictionary([
            "comment": .bytes(Data("https://rutracker.org/forum/viewtopic.php?t=1234".utf8)),
            "info": .dictionary(["name": .bytes(Data("fixture.bin".utf8)), "length": .integer(4),
                                 "piece length": .integer(4), "pieces": .bytes(Data(repeating: 7, count: 20))])
        ]))
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let continuation = self.startup else { return }
                    switch state {
                    case .ready: self.startup = nil; continuation.resume()
                    case .failed(let error): self.startup = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")! }
    func stop() {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, previous: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var request = previous
                if let data { request.append(data) }
                guard request.count <= 16 * 1024, error == nil else { self.close(connection, id: id); return }
                if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                    self.respond(connection, id: id, request: text)
                } else if complete { self.close(connection, id: id) }
                else { self.receive(connection, id: id, previous: request) }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: String) {
        receivedCookie = receivedCookie || request.lowercased().contains("\r\ncookie:")
        let path = request.components(separatedBy: " ").dropFirst().first ?? ""
        var status = "200 OK"
        var headers = "Content-Type: application/x-bittorrent\r\n"
        var body = payload
        switch path {
        case "/attachment":
            headers += "Content-Disposition: attachment; filename=fixture.torrent\r\n"
        case "/truncated":
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-bittorrent\r\nContent-Length: \(payload.count + 1024)\r\nConnection: close\r\n\r\n".utf8) + payload.prefix(8)
            send(connection, id: id, data: response)
            return
        case "/updated":
            if var root = try? Bencode.decode(payload).dictionaryValue, var info = root["info"]?.dictionaryValue {
                info["revision"] = .integer(1)
                root["info"] = .dictionary(info)
                body = Bencode.encode(.dictionary(root))
            }
        case "/html": headers = "Content-Type: text/html\r\n"; body = Data("<html>Sign in</html>".utf8)
        case "/invalid": body = Data("invalid torrent".utf8)
        case "/large-header", "/large-stream":
            let lengthHeader = path == "/large-header" ? "Content-Length: 16842752\r\n" : ""
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\(lengthHeader)Connection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    if error == nil { self?.stream(connection, id: id, remaining: 257) }
                    else { self?.close(connection, id: id) }
                }
            }); return
        case "/slow":
            slowRequested = true
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in }); return
        case "/redirect", "/loop", "/cookie", "/invalid-redirect":
            status = "302 Found"; body = Data()
            let location = path == "/loop" ? url("loop").absoluteString : path == "/invalid-redirect" ? "file:///tmp/torrenza-must-not-read.torrent" : url("valid").absoluteString
            headers = "Location: \(location)\r\n"
            if path == "/cookie" { headers += "Set-Cookie: refresh_smoke=secret; Path=/\r\n" }
        default: break
        }
        var response = Data("HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        send(connection, id: id, data: response)
    }

    private func send(_ connection: NWConnection, id: UUID, data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection, id: id) }
        })
    }

    private func stream(_ connection: NWConnection, id: UUID, remaining: Int) {
        guard remaining > 0 else { close(connection, id: id); return }
        connection.send(content: Data(repeating: 65, count: 64 * 1024), completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if error == nil { self?.stream(connection, id: id, remaining: remaining - 1) }
                else { self?.close(connection, id: id) }
            }
        })
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections.removeValue(forKey: id)
    }
}
#endif
