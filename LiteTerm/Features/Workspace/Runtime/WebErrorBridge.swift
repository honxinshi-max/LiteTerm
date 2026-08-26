import Foundation
import WebKit

enum WebRuntimeIssueKind: String, Sendable {
    case pageLoad
    case resource
    case javascript
    case promise
    case externalNavigation
    case popup
    case download
    case mediaPermission
}

struct WebRuntimeIssue: Equatable, Sendable {
    static let maximumMessageBytes = 256

    let kind: WebRuntimeIssueKind
    let message: String
    let line: Int?
    let column: Int?

    init(kind: WebRuntimeIssueKind, message: String, line: Int? = nil, column: Int? = nil) {
        self.kind = kind
        self.message = Self.bounded(message)
        self.line = line.flatMap { $0 > 0 ? $0 : nil }
        self.column = column.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > maximumMessageBytes else { return value }
        var bytes = Array(value.utf8.prefix(maximumMessageBytes))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}

@MainActor
final class WebErrorBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "LiteTermWebError"
    static let contentWorld = WKContentWorld.world(name: "LiteTerm.WebErrors")

    private let onIssue: (WebRuntimeIssue) -> Void

    init(onIssue: @escaping (WebRuntimeIssue) -> Void) {
        self.onIssue = onIssue
    }

    func install(in controller: WKUserContentController) {
        controller.add(
            self,
            contentWorld: Self.contentWorld,
            name: Self.handlerName
        )
        controller.addUserScript(WKUserScript(
            source: Self.captureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.contentWorld
        ))
    }

    func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: Self.handlerName,
            contentWorld: Self.contentWorld
        )
        controller.removeAllUserScripts()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let envelope = message.body as? [String: Any],
              let rawKind = envelope["kind"] as? String,
              let kind = WebRuntimeIssueKind(rawValue: rawKind) else { return }
        let text = envelope["message"] as? String ?? "Web runtime failure."
        let line = (envelope["line"] as? NSNumber)?.intValue
        let column = (envelope["column"] as? NSNumber)?.intValue
        let issue = WebRuntimeIssue(kind: kind, message: text, line: line, column: column)
        onIssue(issue)
    }

    private static let captureScript = #"""
    (() => {
      const send = (kind, message, line, column) => {
        const text = String(message || 'Web runtime failure').slice(0, 256);
        window.webkit.messageHandlers.LiteTermWebError.postMessage({
          kind,
          message: text,
          line: Number.isFinite(line) ? line : 0,
          column: Number.isFinite(column) ? column : 0
        });
      };
      window.addEventListener('error', (event) => {
        if (event.target && event.target !== window) {
          send('resource', 'A local Web resource failed to load.', 0, 0);
        } else {
          send('javascript', event.message || 'JavaScript runtime exception.', event.lineno, event.colno);
        }
      }, true);
      window.addEventListener('unhandledrejection', (event) => {
        const reason = event.reason && event.reason.message
          ? event.reason.message
          : 'Unhandled promise rejection.';
        send('promise', reason, 0, 0);
      }, true);
    })();
    """#
}
