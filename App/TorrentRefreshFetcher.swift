import AppKit
import CryptoKit
import Foundation
import Observation
import TorrentCore
import WebKit

enum TorrentRefreshFetchError: Error, LocalizedError {
    case busy
    case invalidURL
    case httpStatus(Int)
    case responseIsNotTorrent
    case tooLarge
    case tooManyRedirects
    case timedOut

    var errorDescription: String? {
        switch self {
        case .busy: "A torrent refresh is already in progress."
        case .invalidURL: "Use an HTTP or HTTPS torrent source URL without embedded credentials."
        case .httpStatus(let status): "The torrent source returned HTTP \(status)."
        case .responseIsNotTorrent: "The source returned a webpage instead of a torrent file."
        case .tooLarge: "The torrent file exceeds the 16 MiB limit."
        case .tooManyRedirects: "The torrent source redirected too many times."
        case .timedOut: "The torrent source did not respond in time."
        }
    }
}

/// WebKit owns RuTracker cookies; direct URLs never use those cookies or browser credentials.
@MainActor @Observable final class TorrentRefreshFetcher: NSObject {
    private(set) var isAuthenticationRequired = false
    private(set) var isFetching = false
    private(set) var status = ""
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    @ObservationIgnored private var source: TorrentRefreshSource?
    @ObservationIgnored private var continuation: CheckedContinuation<Data, any Error>?
    @ObservationIgnored private var directTask: Task<Data, any Error>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var activeDownload: WKDownload?
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private var isDownloadHandoff = false
#if DEBUG
    @ObservationIgnored private var browserFixtureURL: URL?
#endif
    @ObservationIgnored private var progressObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var temporaryDirectory: URL?
    @ObservationIgnored private var downloadURL: URL?
    @ObservationIgnored private var redirectCount = 0
    private nonisolated static let maximumBytes = 16 * 1024 * 1024

    init(profileID: String, websiteDataStore injectedStore: WKWebsiteDataStore? = nil) {
        // A stable, namespaced identifier also accommodates the non-UUID Default profile.
        let digest = Array(SHA256.hash(data: Data("dev.torrenza.rutracker.\(profileID)".utf8)).prefix(16))
        let identifier = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                                     digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        let store = injectedStore ?? WKWebsiteDataStore(forIdentifier: identifier)
        websiteDataStore = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func fetch(source proposedSource: TorrentRefreshSource) async throws -> Data {
        guard !isFetching else { throw TorrentRefreshFetchError.busy }
        try Task.checkCancellation()
        let source: TorrentRefreshSource
        switch proposedSource {
        case .ruTracker(let topicID, let host):
            guard ["rutracker.org", "rutracker.net"].contains(host.lowercased()),
                  !topicID.isEmpty, topicID.utf8.count <= 8192,
                  topicID.utf8.allSatisfy({ (48...57).contains($0) }), topicID.contains(where: { $0 != "0" }) else {
                throw TorrentRefreshFetchError.invalidURL
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/forum/viewtopic.php"
            components.queryItems = [URLQueryItem(name: "t", value: topicID)]
            guard let url = components.url else { throw TorrentRefreshFetchError.invalidURL }
            source = try TorrentRefreshSource(url: url)
        case .direct(let url):
            _ = try TorrentRefreshSource(url: url)
            source = .direct(url)
        }
        guard Self.validHTTPURL(source.url) else { throw TorrentRefreshFetchError.invalidURL }
        isFetching = true
        self.source = source
        status = "Fetching updated torrent…"
        defer {
            isFetching = false
            self.source = nil
            directTask = nil
            isAuthenticationRequired = false
            timeoutTask?.cancel()
            timeoutTask = nil
            cleanupDownload()
        }
        return try await withTaskCancellationHandler {
            switch source {
            case .direct(let url):
                let task = Task { try await Self.fetchDirect(url) }
                directTask = task
                if Task.isCancelled { task.cancel() }
                return try await task.value
            case .ruTracker:
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    if Task.isCancelled {
                        finish(.failure(CancellationError()))
                    } else {
                        startRuTrackerDownload()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        directTask?.cancel()
        webView.stopLoading()
        activeNavigation = nil
        finish(.failure(CancellationError()))
    }

#if DEBUG
    /// Exercises the WebKit path against an isolated loopback server, without account cookies.
    func fetchBrowserFixture(url: URL) async throws -> Data {
        guard !isFetching else { throw TorrentRefreshFetchError.busy }
        guard websiteDataStore.isPersistent == false, url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, Self.validHTTPURL(url) else { throw TorrentRefreshFetchError.invalidURL }
        browserFixtureURL = url
        defer { browserFixtureURL = nil }
        return try await fetch(source: .ruTracker(topicID: "1", host: "rutracker.org"))
    }
#endif

    func signOut() async {
        cancel()
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        status = "Signed out of RuTracker."
    }

    func openLogin() {
        guard case .ruTracker(_, let host) = source,
              let url = URL(string: "https://\(host)/forum/login.php") else { return }
        showAuthentication()
        activeNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
    }

    func continueAfterAuthentication() {
        guard continuation != nil else { return }
        isAuthenticationRequired = false
        startRuTrackerDownload()
    }

    private func startRuTrackerDownload() {
        guard let source, case .ruTracker(let topicID, let host) = source, continuation != nil else { return }
        redirectCount = 0
        isDownloadHandoff = false
        status = "Fetching updated torrent…"
        startTimeout()
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/forum/dl.php"
        components.queryItems = [URLQueryItem(name: "t", value: topicID)]
        guard let url = components.url else { finish(.failure(TorrentRefreshFetchError.invalidURL)); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
#if DEBUG
        if let browserFixtureURL { request.url = browserFixtureURL }
#endif
        request.setValue(source.url.absoluteString, forHTTPHeaderField: "Referer")
        activeNavigation = webView.load(request)
    }

    private func showAuthentication() {
        timeoutTask?.cancel()
        timeoutTask = nil
        status = "Sign in or complete RuTracker’s browser check, then click Continue."
        isAuthenticationRequired = true
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.finish(.failure(TorrentRefreshFetchError.timedOut))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isAuthenticationRequired = false
        webView.stopLoading()
        activeNavigation = nil
        cleanupDownload()
        continuation.resume(with: result)
    }

    private func cleanupDownload() {
        isDownloadHandoff = false
        progressObservations.removeAll()
        let download = activeDownload
        activeDownload = nil
        let directory = temporaryDirectory
        temporaryDirectory = nil
        downloadURL = nil
        if let download {
            // Wait until WebKit stops writing before removing its destination.
            download.cancel { _ in
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        } else if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func receive(_ download: WKDownload) {
        guard continuation != nil, activeDownload == nil else {
            download.cancel(nil)
            return
        }
        activeDownload = download
        download.delegate = self
        startTimeout()
        let check: @Sendable (Progress, NSKeyValueObservedChange<Int64>) -> Void = { [weak self, weak download] progress, _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                guard let self, let download, self.activeDownload === download else { return }
                if completed > Self.maximumBytes || total > Self.maximumBytes {
                    self.finish(.failure(TorrentRefreshFetchError.tooLarge))
                }
            }
        }
        progressObservations = [download.progress.observe(\.completedUnitCount, options: [.initial, .new], changeHandler: check),
                                download.progress.observe(\.totalUnitCount, options: [.initial, .new], changeHandler: check)]
    }

    private nonisolated static func validHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    private nonisolated static func ruTrackerURL(_ url: URL?) -> Bool {
        guard let url, validHTTPURL(url), let host = url.host?.lowercased() else { return false }
        return host == "rutracker.org" || host == "rutracker.net" || host.hasSuffix(".rutracker.org") || host.hasSuffix(".rutracker.net")
    }

    private func allowedBrowserURL(_ url: URL?) -> Bool {
#if DEBUG
        if let fixture = browserFixtureURL {
            guard let url, Self.validHTTPURL(url) else { return false }
            return url.scheme == fixture.scheme && url.host == fixture.host && url.port == fixture.port
        }
#endif
        return Self.ruTrackerURL(url)
    }

    private nonisolated static func fetchDirect(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let redirects = TorrentRefreshRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        if let error = redirects.error { throw error }
        guard let response = response as? HTTPURLResponse else { throw TorrentRefreshFetchError.responseIsNotTorrent }
        guard (200..<300).contains(response.statusCode) else { throw TorrentRefreshFetchError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw TorrentRefreshFetchError.tooLarge }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime != "text/html", mime != "application/xhtml+xml" else { throw TorrentRefreshFetchError.responseIsNotTorrent }
        var data = Data()
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count + buffer.count < maximumBytes else { throw TorrentRefreshFetchError.tooLarge }
            buffer.append(byte)
            if buffer.count == 64 * 1024 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: buffer)
        return data
    }
}

extension TorrentRefreshFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard continuation != nil else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            guard allowedBrowserURL(navigationAction.request.url) else { decisionHandler(.cancel); return }
        }
        // Captcha resources and challenge frames may come from separate provider origins.
        guard navigationAction.targetFrame != nil else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard continuation != nil else { decisionHandler(.cancel); return }
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        guard allowedBrowserURL(navigationResponse.response.url) else {
            decisionHandler(.cancel)
            finish(.failure(TorrentRefreshFetchError.invalidURL))
            return
        }
        let response = navigationResponse.response
        let mime = response.mimeType?.lowercased() ?? ""
        let html = mime == "text/html" || mime == "application/xhtml+xml"
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if html && [401, 403].contains(http.statusCode) {
                showAuthentication()
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                finish(.failure(TorrentRefreshFetchError.httpStatus(http.statusCode)))
            }
            return
        }
        if html {
            showAuthentication()
            decisionHandler(.allow)
        } else if response.expectedContentLength > Self.maximumBytes {
            decisionHandler(.cancel)
            finish(.failure(TorrentRefreshFetchError.tooLarge))
        } else {
            // WebKit may report policy interruption before delivering didBecome download.
            // Record the handoff before invoking its decision handler.
            isDownloadHandoff = true
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { receive(download) }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { receive(download) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard let navigation, navigation === activeNavigation else { return }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        // A response becoming a download interrupts its frame load by policy. The
        // download delegate and timeout remain responsible for success or failure.
        if isDownloadHandoff && failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }
        finish(.failure(error))
    }
}

extension TorrentRefreshFetcher: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard download === activeDownload, continuation != nil else { completionHandler(nil); return }
        guard response.expectedContentLength <= Self.maximumBytes else {
            completionHandler(nil)
            finish(.failure(TorrentRefreshFetchError.tooLarge))
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-refresh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
            let destination = directory.appendingPathComponent("refresh.torrent")
            downloadURL = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            finish(.failure(error))
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === activeDownload, let downloadURL else { return }
        activeDownload = nil
        do {
            let size = try downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw TorrentRefreshFetchError.tooLarge }
            let data = try Data(contentsOf: downloadURL)
            guard data.count <= Self.maximumBytes else { throw TorrentRefreshFetchError.tooLarge }
            finish(.success(data))
        } catch { finish(.failure(error)) }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard download === activeDownload else { return }
        finish(.failure(error))
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        redirectCount += 1
        guard download === activeDownload, continuation != nil, redirectCount <= 5, allowedBrowserURL(newRequest.url) else {
            decisionHandler(.cancel)
            finish(.failure(redirectCount > 5 ? TorrentRefreshFetchError.tooManyRedirects : TorrentRefreshFetchError.invalidURL))
            return
        }
        decisionHandler(.allow)
    }
}

/// URLSession delivers redirects on its delegate queue; lock the small state read by fetchDirect.
private final class TorrentRefreshRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failure: TorrentRefreshFetchError?
    var error: TorrentRefreshFetchError? { lock.withLock { failure } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = lock.withLock {
            count += 1
            if count > 5 { failure = .tooManyRedirects; return false }
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { failure = .invalidURL; return false }
            return true
        }
        completionHandler(allowed ? request : nil)
    }
}
