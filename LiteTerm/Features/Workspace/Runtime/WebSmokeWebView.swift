import Foundation
import WebKit

@MainActor
final class WebSmokeWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let allowedPort: Int
    private let ruleIdentifier = "LiteTerm.WebSmoke.\(UUID().uuidString)"
    private var webView: WKWebView?
    private var bridge: WebErrorBridge?
    private var issues: [WebRuntimeIssue] = []
    private var continuation: CheckedContinuation<[WebRuntimeIssue], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var finished = false

    private init(allowedPort: Int) {
        self.allowedPort = allowedPort
    }

    static func run(
        url: URL,
        allowedPort: Int,
        timeout: Duration
    ) async -> [WebRuntimeIssue] {
        let session = WebSmokeWebView(allowedPort: allowedPort)
        return await session.start(url: url, timeout: timeout)
    }

    private func start(url: URL, timeout: Duration) async -> [WebRuntimeIssue] {
        guard Self.isAllowed(url: url, port: allowedPort) else {
            return [WebRuntimeIssue(
                kind: .externalNavigation,
                message: "The preview attempted to leave its private loopback origin."
            )]
        }

        do {
            let ruleList = try await compileRuleList()
            let controller = WKUserContentController()
            controller.add(ruleList)
            let bridge = WebErrorBridge { [weak self] issue in self?.record(issue) }
            bridge.install(in: controller)

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = controller
            // Requests reach the UI delegate so LiteTerm can record and deny them explicitly.
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true

            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            self.bridge = bridge
            webView = view
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    self.timeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.record(WebRuntimeIssue(
                            kind: .pageLoad,
                            message: "The Web smoke test timed out."
                        ))
                        self?.finish()
                    }
                    var request = URLRequest(
                        url: url,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 5
                    )
                    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                    view.load(request)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish() }
            }
        } catch {
            return [WebRuntimeIssue(
                kind: .pageLoad,
                message: "The isolated Web policy could not be prepared."
            )]
        }
    }

    private func compileRuleList() async throws -> WKContentRuleList {
        let port = allowedPort
        let source = """
        [
          {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:\(port)/"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: ruleIdentifier,
                encodedContentRuleList: source
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: error ?? PreviewRuntimeError.unavailable)
                }
            }
        }
    }

    private func record(_ issue: WebRuntimeIssue) {
        guard !finished, issues.count < 100, !issues.contains(issue) else { return }
        issues.append(issue)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        timeoutTask = nil
        settleTask = nil
        webView?.stopLoading()
        if let controller = webView?.configuration.userContentController {
            bridge?.uninstall(from: controller)
        }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        bridge = nil
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleIdentifier) { _ in }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: issues)
    }

    private static func isAllowed(url: URL, port: Int) -> Bool {
        url.scheme?.lowercased() == "http"
            && url.host == "127.0.0.1"
            && url.port == port
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(WebRuntimeIssue(kind: .pageLoad, message: "The Web page failed to load."))
        finish()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        record(WebRuntimeIssue(kind: .pageLoad, message: "The Web page failed to start loading."))
        finish()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              Self.isAllowed(url: url, port: allowedPort) else {
            record(WebRuntimeIssue(
                kind: navigationAction.targetFrame == nil ? .popup : .externalNavigation,
                message: "External navigation or a popup was blocked."
            ))
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            record(WebRuntimeIssue(kind: .download, message: "A Web download was blocked."))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard !navigationResponse.isForMainFrame || navigationResponse.canShowMIMEType else {
            record(WebRuntimeIssue(kind: .download, message: "A Web download was blocked."))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        record(WebRuntimeIssue(kind: .popup, message: "A Web popup was blocked."))
        return nil
    }

    @available(iOS 15.0, macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        record(WebRuntimeIssue(kind: .mediaPermission, message: "Media capture was blocked."))
        decisionHandler(.deny)
    }
}
