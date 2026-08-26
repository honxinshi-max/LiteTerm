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
    var onDeletionConfirmationChanged: ((DeletionConfirmationRequest?) -> Void)?
    var onWorkspaceAction: ((WorkspaceShellAction) -> Void)?

    private weak var terminalView: TerminalView?
    private var localShell: LocalShell
    private let localOperationQueue: LocalOperationQueue
    private var localInputReducer = LocalTerminalInputReducer()
    private var shortcutReducer = ShortcutInputReducer()
    private var remoteOutputSanitizer = RemoteOutputSanitizer()
    private var didPresentLocalPrompt = false
    private var flowState: TerminalFlowStateReducer
    private var isLocalInputSuspended = false
    private var pendingDeletion: (
        request: DeletionConfirmationRequest,
        shell: LocalShell,
        generation: UInt64
    )?

    var activeWorkspaceID: String { flowState.activeWorkspaceID }

    init(
        rootURL: URL,
        coordinateFileAccess: Bool = false,
        localOperationQueue: LocalOperationQueue? = nil
    ) {
        let fileSystem: (any LocalFileSystemAccess)? = coordinateFileAccess
            ? CoordinatedLocalFileSystem(rootURL: rootURL)
            : nil
        localShell = LocalShell(rootURL: rootURL, fileSystem: fileSystem)
        flowState = TerminalFlowStateReducer(initialWorkspaceID: rootURL.path)
        self.localOperationQueue = localOperationQueue ?? LocalOperationQueue()
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
        invalidatePendingDeletion()
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
        invalidatePendingDeletion()
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
        if mode == .local {
            switch key {
            case .up:
                applyLocalEvents(localInputReducer.navigateHistory(.previous))
                return
            case .down:
                applyLocalEvents(localInputReducer.navigateHistory(.next))
                return
            default:
                break
            }
        }
        let bytes = shortcutReducer.handleShortcut(key)
        publishShortcutState()
        routeInput(bytes)
    }

    @discardableResult
    func runLocalCommand(_ command: String) -> Bool {
        let shell = localShell
        let generation = flowState.generation
        let accepted = localOperationQueue.enqueue(operationCost: command.utf8.count) { [weak self] in
            let execution = await shell.execute(command)
            await self?.present(execution, shell: shell, generation: generation)
        }
        if !accepted {
            presentLocalQueueBusy(generation: generation)
        }
        return accepted
    }

    @discardableResult
    func receiveRemoteBytes(_ bytes: [UInt8]) -> Bool {
        guard mode == .ssh, flowState.activeMode == .ssh else { return false }
        let sanitized = remoteOutputSanitizer.sanitize(bytes)
        guard !sanitized.isEmpty else { return false }
        terminalView?.feed(byteArray: sanitized[...])
        return true
    }

    func confirmDeletion(_ request: DeletionConfirmationRequest) {
        guard
            let pendingDeletion,
            pendingDeletion.request == request,
            mode == .local,
            flowState.activeMode == .local,
            flowState.generation == pendingDeletion.generation
        else {
            invalidatePendingDeletion()
            return
        }
        self.pendingDeletion = nil
        onDeletionConfirmationChanged?(nil)
        let requestCost = request.rootRelativePath.utf8.count
            + (request.fileIdentity.resourceIdentifier?.count ?? 0)
            + 32
        let accepted = localOperationQueue.enqueue(operationCost: requestCost) { [weak self] in
            let execution = await pendingDeletion.shell.confirmDeletion(request)
            await self?.present(
                execution,
                shell: pendingDeletion.shell,
                generation: pendingDeletion.generation
            )
        }
        if !accepted {
            presentLocalQueueBusy(generation: pendingDeletion.generation)
        }
    }

    func cancelDeletion(_ request: DeletionConfirmationRequest) {
        guard let pendingDeletion, pendingDeletion.request == request else { return }
        self.pendingDeletion = nil
        onDeletionConfirmationChanged?(nil)
        let requestCost = request.rootRelativePath.utf8.count
            + (request.fileIdentity.resourceIdentifier?.count ?? 0)
            + 32
        let accepted = localOperationQueue.enqueue(operationCost: requestCost) {
            await pendingDeletion.shell.cancelDeletion(request)
        }
        if !accepted {
            presentLocalQueueBusy(generation: pendingDeletion.generation)
        }
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

    func presentWorkspaceSummary(_ lines: [String]) {
        guard mode == .local, flowState.activeMode == .local else { return }
        var output = BoundedRuntimeOutput(lineLimit: 20, byteLimit: 4 * 1_024)
        for line in lines {
            let safeScalars = line.unicodeScalars.filter { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
            output.append(String(String.UnicodeScalarView(safeScalars)))
        }
        terminalView?.feed(text: "\r\n")
        for line in output.lines {
            terminalView?.feed(text: line + "\r\n")
        }
        terminalView?.feed(text: "$ ")
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
        if bytes == [0x1B, 0x5B, 0x41] {
            applyLocalEvents(localInputReducer.navigateHistory(.previous))
            return
        }
        if bytes == [0x1B, 0x5B, 0x42] {
            applyLocalEvents(localInputReducer.navigateHistory(.next))
            return
        }
        if bytes.first == 0x1B {
            return
        }

        applyLocalEvents(localInputReducer.reduce(bytes))
    }

    private func applyLocalEvents(_ events: [LocalTerminalInputEvent]) {
        for event in events {
            switch event {
            case let .echo(echoedBytes):
                terminalView?.feed(byteArray: echoedBytes[...])
            case .erase:
                terminalView?.feed(text: "\u{8} \u{8}")
            case .interrupt:
                terminalView?.feed(text: "^C\r\n")
                let generation = flowState.generation
                let accepted = localOperationQueue.enqueue { [weak self] in
                    await self?.presentPrompt(generation: generation)
                }
                if !accepted {
                    presentLocalQueueBusy(generation: generation)
                }
            case let .replaceLine(replacement):
                terminalView?.feed(text: "\r\u{1B}[2K$ ")
                terminalView?.feed(byteArray: replacement[...])
            case let .submit(command):
                terminalView?.feed(text: "\r\n")
                runLocalCommand(command)
            }
        }
    }

    private func present(
        _ execution: ShellExecution,
        shell: LocalShell,
        generation: UInt64
    ) {
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
        if let request = execution.deletionConfirmationRequest {
            pendingDeletion = (request, shell, generation)
            onDeletionConfirmationChanged?(request)
        }
        if let workspaceAction = execution.workspaceAction {
            onWorkspaceAction?(workspaceAction)
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

    private func presentLocalQueueBusy(generation: UInt64) {
        guard
            mode == .local,
            flowState.activeMode == .local,
            flowState.generation == generation
        else { return }
        terminalView?.feed(text: "Error: Local command queue is busy\r\n$ ")
    }

    private func publishShortcutState() {
        isControlLatched = shortcutReducer.isControlLatched
    }

    private func invalidatePendingDeletion() {
        guard pendingDeletion != nil else { return }
        pendingDeletion = nil
        onDeletionConfirmationChanged?(nil)
    }
}
