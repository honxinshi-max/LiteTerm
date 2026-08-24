import SwiftUI
@preconcurrency import SwiftTerm
import UIKit

struct TerminalViewRepresentable: UIViewRepresentable {
    @ObservedObject var session: TerminalSessionCoordinator

    func makeCoordinator() -> Delegate {
        Delegate(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 15, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.changeScrollback(2_000)
        view.getTerminal().options.termName = "xterm-256color"
        view.getTerminal().options.enableSixelReported = false
        view.getTerminal().options.kittyImageCacheLimitBytes = 0
        view.allowMouseReporting = false
        view.nativeBackgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.055, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.caretColor = UIColor(red: 0.35, green: 0.87, blue: 0.67, alpha: 1)
        view.indicatorStyle = .white
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "Terminal view"
        session.attachTerminalView(view)
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.session = session
        session.attachTerminalView(uiView)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Delegate) {
        coordinator.session.detachTerminalView(uiView)
        uiView.terminalDelegate = nil
        uiView.updateUiClosed()
    }

    @MainActor
    final class Delegate: NSObject, TerminalViewDelegate {
        var session: TerminalSessionCoordinator

        init(session: TerminalSessionCoordinator) {
            self.session = session
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.terminalSizeChanged(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.sendBytes(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
