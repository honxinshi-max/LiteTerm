import Combine
import Foundation
import LiteTermCore
@preconcurrency import SwiftTerm

enum TerminalMode: String, CaseIterable, Identifiable {
    case local = "Local"
    case ssh = "SSH"

    var id: Self { self }
}

enum RemoteTerminalStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Connection failed"
}

@MainActor
final class TerminalSessionCoordinator: ObservableObject {
    typealias RemoteInputHandler = ([UInt8]) -> Void
    typealias RemoteResizeHandler = (_ columns: Int, _ rows: Int) -> Void

    @Published private(set) var mode: TerminalMode = .local
    @Published private(set) var isControlLatched = false
    @Published private(set) var remoteStatus: RemoteTerminalStatus = .disconnected

    var onRemoteInput: RemoteInputHandler?
    var onRemoteResize: RemoteResizeHandler?
    var onEditorRequested: ((URL) -> Void)?

    private weak var terminalView: TerminalView?
    private var localShell: LocalShell
    private var localInput = [UInt8]()
    private var shortcutReducer = ShortcutInputReducer()
    private var didPresentLocalPrompt = false
    private var localGeneration = 0
    private var didReceiveCarriageReturn = false

    init(rootURL: URL, coordinateFileAccess: Bool = false) {
        let fileSystem: (any LocalFileSystemAccess)? = coordinateFileAccess
            ? CoordinatedLocalFileSystem(rootURL: rootURL)
            : nil
        localShell = LocalShell(rootURL: rootURL, fileSystem: fileSystem)
    }

    func attachTerminalView(_ view: TerminalView) {
        terminalView = view
        guard mode == .local, !didPresentLocalPrompt else { return }
        didPresentLocalPrompt = true
        view.feed(text: "LiteTerm Local\r\n$ ")
    }

    func detachTerminalView(_ view: TerminalView) {
        guard terminalView === view else { return }
        terminalView = nil
    }

    func setMode(_ newMode: TerminalMode) {
        guard mode != newMode else { return }
        mode = newMode
        localGeneration += 1
        localInput.removeAll(keepingCapacity: true)
        didReceiveCarriageReturn = false
        shortcutReducer = ShortcutInputReducer()
        publishShortcutState()
        if newMode == .local {
            if let terminalView {
                terminalView.feed(text: "\r\n$ ")
                didPresentLocalPrompt = true
            } else {
                didPresentLocalPrompt = false
            }
        }
    }

    func replaceLocalRoot(with rootURL: URL, coordinateFileAccess: Bool = false) {
        let fileSystem: (any LocalFileSystemAccess)? = coordinateFileAccess
            ? CoordinatedLocalFileSystem(rootURL: rootURL)
            : nil
        localShell = LocalShell(rootURL: rootURL, fileSystem: fileSystem)
        localGeneration += 1
        localInput.removeAll(keepingCapacity: true)
        didReceiveCarriageReturn = false
        if mode == .local {
            terminalView?.feed(text: "\r\n$ ")
        }
    }

    func sendText(_ text: String) {
        let bytes = shortcutReducer.reduceText(text)
        publishShortcutState()
        routeInput(bytes)
    }

    func sendBytes(_ bytes: [UInt8]) {
        let reduced: [UInt8]
        if bytes.first == 0x1B {
            reduced = bytes
        } else {
            reduced = shortcutReducer.reduceBytes(bytes)
        }
        publishShortcutState()
        routeInput(reduced)
    }

    func handleShortcut(_ key: TerminalShortcutKey) {
        let bytes = shortcutReducer.handleShortcut(key)
        publishShortcutState()
        routeInput(bytes)
    }

    func runLocalCommand(_ command: String) {
        let shell = localShell
        let generation = localGeneration
        Task { [weak self] in
            let execution = await shell.execute(command)
            guard let self, self.mode == .local, self.localGeneration == generation else { return }
            present(execution)
        }
    }

    func receiveRemoteBytes(_ bytes: [UInt8]) {
        guard mode == .ssh else { return }
        terminalView?.feed(byteArray: bytes[...])
    }

    func terminalSizeChanged(columns: Int, rows: Int) {
        guard mode == .ssh else { return }
        onRemoteResize?(columns, rows)
    }

    func updateRemoteStatus(_ status: RemoteTerminalStatus) {
        remoteStatus = status
    }

    private func routeInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        switch mode {
        case .local:
            processLocalInput(bytes)
        case .ssh:
            onRemoteInput?(bytes)
        }
    }

    private func processLocalInput(_ bytes: [UInt8]) {
        if bytes.first == 0x1B {
            return
        }

        var echoed = [UInt8]()
        for byte in bytes {
            switch byte {
            case 0x03:
                localInput.removeAll(keepingCapacity: true)
                didReceiveCarriageReturn = false
                terminalView?.feed(text: "^C\r\n$ ")
            case 0x08, 0x7F:
                guard !localInput.isEmpty else { continue }
                if let current = String(bytes: localInput, encoding: .utf8) {
                    localInput = Array(current.dropLast().utf8)
                } else {
                    localInput.removeLast()
                }
                didReceiveCarriageReturn = false
                terminalView?.feed(text: "\u{8} \u{8}")
            case 0x0D:
                didReceiveCarriageReturn = true
                terminalView?.feed(text: "\r\n")
                let command = String(decoding: localInput, as: UTF8.self)
                localInput.removeAll(keepingCapacity: true)
                runLocalCommand(command)
            case 0x0A:
                if didReceiveCarriageReturn {
                    didReceiveCarriageReturn = false
                    continue
                }
                terminalView?.feed(text: "\r\n")
                let command = String(decoding: localInput, as: UTF8.self)
                localInput.removeAll(keepingCapacity: true)
                runLocalCommand(command)
            default:
                didReceiveCarriageReturn = false
                localInput.append(byte)
                echoed.append(byte)
            }
        }

        if !echoed.isEmpty {
            terminalView?.feed(text: String(decoding: echoed, as: UTF8.self))
        }
    }

    private func present(_ execution: ShellExecution) {
        if execution.clearRequested {
            terminalView?.feed(text: "\u{1B}[2J\u{1B}[3J\u{1B}[H")
        }
        for line in execution.outputLines {
            terminalView?.feed(text: line + "\r\n")
        }
        if let editorURL = execution.editorURL {
            onEditorRequested?(editorURL)
        }
        terminalView?.feed(text: "$ ")
    }

    private func publishShortcutState() {
        isControlLatched = shortcutReducer.isControlLatched
    }
}
