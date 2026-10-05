import SwiftUI
import WebKit

struct RuTrackerLoginView: View {
    let fetcher: TorrentRefreshFetcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RuTracker").font(.title2.bold())
            Text(fetcher.status).foregroundStyle(.secondary)
            RuTrackerBrowser(webView: fetcher.webView)
                .frame(minWidth: 700, minHeight: 480)
            HStack {
                Button("Cancel") { fetcher.cancel() }.keyboardShortcut(.cancelAction)
                Button("Sign out") { Task { await fetcher.signOut() } }
                Spacer()
                Button("Sign in") { fetcher.openLogin() }
                Button("Continue") { fetcher.continueAfterAuthentication() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct RuTrackerBrowser: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
