import SwiftUI
import WebKit

struct RuTrackerLoginView: View {
    let fetcher: TorrentRefreshFetcher

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
            SheetHeader(title: "RuTracker", subtitle: fetcher.status, systemImage: "person.crop.circle")
            RuTrackerBrowser(webView: fetcher.webView)
                .frame(minWidth: 700, minHeight: 480)
            SheetFooter {
                EmptyView()
            } actions: {
                Button("Cancel") { fetcher.cancel() }.keyboardShortcut(.cancelAction)
                Button("Sign out") { Task { await fetcher.signOut() } }
                Spacer(minLength: WorkspaceMetrics.space2)
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
