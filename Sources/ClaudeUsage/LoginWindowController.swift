import AppKit
import WebKit

/// Shows claude.ai's own login page in a web view. Once the `sessionKey`
/// cookie appears in the (persistent) cookie store, sign-in is complete.
@MainActor
final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let webView: WKWebView
    private let dataStore: WKWebsiteDataStore
    private var finished = false
    var onSuccess: (() -> Void)?
    var onClose: (() -> Void)?

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: config)
        webView.customUserAgent = UsageService.userAgent

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        dataStore.httpCookieStore.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func checkForSession() {
        guard !finished else { return }
        Task { @MainActor in
            let cookies = await dataStore.httpCookieStore.allCookies()
            let hasSession = cookies.contains { $0.domain.hasSuffix("claude.ai") && $0.name == "sessionKey" && !$0.value.isEmpty }
            guard hasSession, !finished else { return }
            finished = true
            dataStore.httpCookieStore.remove(self)
            window?.close()
            onSuccess?()
        }
    }

    // MARK: WKHTTPCookieStoreObserver
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.checkForSession() }
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession()
    }

    // Google / SSO popups: load them in the same view instead of dropping them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        dataStore.httpCookieStore.remove(self)
        onClose?()
    }
}
