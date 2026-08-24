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
    case awaitingHostTrust = "Verify host key"
    case authenticating = "Authenticating"
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    case failed = "Connection failed"
}

@MainActor
final class TerminalSessionCoordinator: ObservableObject {
    typealias RemoteInputHandler = ([UInt8]) -> Void
    typealias RemoteResizeHandler = (_ columns: Int, _ rows: Int) -> Void

    @Published private(set) var mode: TerminalMode = .local
    @Published private(set) var isControlLatched = false
    @Published private(set) var remoteStatus: RemoteTerminalStatus = .disconnected
    private(set) var currentTerminalSize = SSHTerminalDimensions.fallback

    var onRemoteInput: RemoteInputHandler?
    var onRemoteResize: RemoteResizeHandler?
    var onEditorRequested: ((URL) -> Void)?

    private weak var terminalView: TerminalView?
    private var localShell: LocalShell
    private let localOperationQueue = LocalOperationQueue()
    private var localInputReducer = LocalTerminalInputReducer()
    private var shortcutReducer = ShortcutInputReducer()
    private var remoteOutputSanitizer = RemoteOutputSanitizer()
    private var didPresentLocalPrompt = false
    private var flowState: TerminalFlowStateReducer
    private var isLocalInputSuspended = false

    init(rootURL: URL, coordinateFileAccess: Bool = false) {
        let fileSystem: (any LocalFileSystemAccess)? = coordinateFileAccess
            ? CoordinatedLocalFileSystem(rootURL: rootURL)
            : nil
        localShell = LocalShell(rootURL: rootURL, fileSystem: fileSystem)
        flowState = TerminalFlowStateReducer(initialWorkspaceID: rootURL.path)
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
        switch newMode {
        case .local:
            flowState.returnToLocal()
        case .ssh:
            break
        }
        localInputReducer.reset()
        shortcutReducer = ShortcutInputReducer()
        remoteOutputSanitizer = RemoteOutputSanitizer()
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

    func suspendLocalInputAndDrain() async {
        isLocalInputSuspended = true
        localInputReducer.reset()
        shortcutReducer = ShortcutInputReducer()
        publishShortcutState()
        await localOperationQueue.suspendAndDrain()
    }

    func installLocalRoot(_ rootURL: URL, coordinateFileAccess: Bool = false) {
        assert(isLocalInputSuspended, "Local root replacement requires a drained input queue")
        let fileSystem: (any LocalFileSystemAccess)? = coordinateFileAccess
            ? CoordinatedLocalFileSystem(rootURL: rootURL)
            : nil
        localShell = LocalShell(rootURL: rootURL, fileSystem: fileSystem)
        flowState.selectLocalWorkspace(id: rootURL.path)
        localInputReducer.reset()
        if mode == .local {
            terminalView?.feed(text: "\r\n$ ")
        }
    }

    func resumeLocalInput() {
        localOperationQueue.resume()
        isLocalInputSuspended = false
    }

    func sendText(_ text: String) {
        guard mode != .local || !isLocalInputSuspended else { return }
        let bytes = shortcutReducer.reduceText(text)
        publishShortcutState()
        routeInput(bytes)
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard mode != .local || !isLocalInputSuspended else { return }
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
        guard mode != .local || !isLocalInputSuspended else { return }
        let bytes = shortcutReducer.handleShortcut(key)
        publishShortcutState()
        routeInput(bytes)
    }

    func runLocalCommand(_ command: String) {
        let shell = localShell
        let generation = flowState.generation
        localOperationQueue.enqueue { [weak self] in
            let execution = await shell.execute(command)
            await self?.present(execution, generation: generation)
        }
    }

    func receiveRemoteBytes(_ bytes: [UInt8]) {
        guard mode == .ssh else { return }
        let sanitized = remoteOutputSanitizer.sanitize(bytes)
        guard !sanitized.isEmpty else { return }
        terminalView?.feed(byteArray: sanitized[...])
    }

    func selectSSHHost(_ hostID: UUID) {
        flowState.selectSSHHost(id: hostID)
    }

    func beginSSHConnection(generation: UInt64, state: SSHConnectionState) {
        _ = flowState.beginSSHConnection(generation: generation, state: state)
    }

    func updateSSHConnectionState(_ state: SSHConnectionState, generation: UInt64) {
        _ = flowState.updateSSHConnectionState(state, generation: generation)
    }

    func disconnectSSH() {
        flowState.disconnectSSH()
    }

    func terminalSizeChanged(columns: Int, rows: Int) {
        currentTerminalSize = SSHTerminalDimensions(columns: columns, rows: rows)
        guard mode == .ssh else { return }
        onRemoteResize?(currentTerminalSize.columns, currentTerminalSize.rows)
    }

    func updateRemoteStatus(_ status: RemoteTerminalStatus) {
        if status == .connecting || status == .reconnecting {
            remoteOutputSanitizer = RemoteOutputSanitizer()
        }
        remoteStatus = status
    }

    private func routeInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        switch mode {
        case .local:
            guard !isLocalInputSuspended else { return }
            processLocalInput(bytes)
        case .ssh:
            guard let routed = flowState.routeRemoteInput(bytes) else { return }
            onRemoteInput?(routed)
        }
    }

    private func processLocalInput(_ bytes: [UInt8]) {
        if bytes.first == 0x1B {
            return
        }

        for event in localInputReducer.reduce(bytes) {
            switch event {
            case let .echo(echoedBytes):
                terminalView?.feed(byteArray: echoedBytes[...])
            case .erase:
                terminalView?.feed(text: "\u{8} \u{8}")
            case .interrupt:
                terminalView?.feed(text: "^C\r\n")
                let generation = localGeneration
                localOperationQueue.enqueue { [weak self] in
                    await self?.presentPrompt(generation: generation)
                }
            case let .submit(command):
                terminalView?.feed(text: "\r\n")
                runLocalCommand(command)
            }
        }
    }

    private func present(_ execution: ShellExecution, generation: UInt64) {
        guard
            mode == .local,
            flowState.activeMode == .local,
            flowState.generation == generation
        else { return }
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

    private func presentPrompt(generation: UInt64) {
        guard
            mode == .local,
            flowState.activeMode == .local,
            flowState.generation == generation
        else { return }
        terminalView?.feed(text: "$ ")
    }

    private func publishShortcutState() {
        isControlLatched = shortcutReducer.isControlLatched
    }
}
