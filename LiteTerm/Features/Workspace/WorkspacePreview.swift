import SwiftUI
import WebKit

struct WorkspacePreview: View {
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        Group {
            if let port = controller.presentation.publishedPort,
               let url = controller.authenticatedPreviewURL() {
                PrivateWorkspaceWebView(url: url, allowedPort: port)
                    .id(port)
            } else {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "safari",
                    description: Text("Run the complete gate to create a verified private preview.")
                )
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace preview")
    }
}

private struct PrivateWorkspaceWebView: UIViewRepresentable {
    let url: URL
    let allowedPort: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedPort: allowedPort)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.isInspectable = false
        view.accessibilityIdentifier = "Private workspace web preview"
        context.coordinator.installPolicyAndLoad(url: url, in: view)
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(url: url, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let allowedPort: Int
        private let ruleIdentifier = "LiteTerm.WorkspacePreview.\(UUID().uuidString)"
        private var loadedURL: URL?
        private var policyInstalled = false

        init(allowedPort: Int) {
            self.allowedPort = allowedPort
        }

        func installPolicyAndLoad(url: URL, in webView: WKWebView) {
            let rules = """
            [
              {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:\(allowedPort)/"},"action":{"type":"ignore-previous-rules"}}
            ]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: ruleIdentifier,
                encodedContentRuleList: rules
            ) { [weak self, weak webView] ruleList, _ in
                Task { @MainActor in
                    guard let self, let webView, let ruleList else { return }
                    webView.configuration.userContentController.add(ruleList)
                    self.policyInstalled = true
                    self.loadIfNeeded(url: url, in: webView)
                }
            }
        }

        func loadIfNeeded(url: URL, in webView: WKWebView) {
            guard policyInstalled, loadedURL != url, isAllowed(url) else { return }
            loadedURL = url
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 5
            )
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            webView.load(request)
        }

        func stop(_ webView: WKWebView) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            loadedURL = nil
            WKContentRuleListStore.default().removeContentRuleList(
                forIdentifier: ruleIdentifier
            ) { _ in }
        }

        private func isAllowed(_ url: URL?) -> Bool {
            url?.scheme?.lowercased() == "http"
                && url?.host == "127.0.0.1"
                && url?.port == allowedPort
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard isAllowed(navigationAction.request.url),
                  navigationAction.targetFrame != nil,
                  !navigationAction.shouldPerformDownload else {
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
            nil
        }

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }
    }
}
