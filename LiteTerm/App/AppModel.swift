import Combine
import Foundation
import LiteTermCore
import SwiftUI

struct EditorDocument: Identifiable {
    let url: URL
    var id: URL { url }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: TerminalMode = .local {
        didSet {
            terminalSession.setMode(mode)
            if mode == .local {
                sshSession.disconnect()
            }
        }
    }
    @Published var isShowingFolderPicker = false
    @Published var isShowingHosts = false
    @Published var editorDocument: EditorDocument?
    @Published var deletionConfirmationRequest: DeletionConfirmationRequest?
    @Published var authorizationErrorMessage: String?
    @Published private(set) var activeWorkspaceName: String

    let folderAuthorizationStore: FolderAuthorizationStore
    let hostStore: HostStore
    let terminalSession: TerminalSessionCoordinator
    let sshSession: SSHSessionController
    private let workspaceTransitionScheduler: WorkspaceTransitionScheduler

    var onHostsRequested: (() -> Void)?
    var canRequestHosts: Bool { onHostsRequested != nil }

    convenience init() {
        self.init(
            folderAuthorizationStore: FolderAuthorizationStore(),
            secrets: KeychainStore()
        )
    }

    init(
        folderAuthorizationStore authorizationStore: FolderAuthorizationStore,
        secrets: any HostSecretStoring,
        sshClientFactory: @escaping SSHSessionController.ClientFactory = { SSHClient(configuration: $0) },
        workspaceTransitionScheduler: WorkspaceTransitionScheduler = WorkspaceTransitionScheduler()
    ) {
        folderAuthorizationStore = authorizationStore
        hostStore = HostStore(secrets: secrets)
        self.workspaceTransitionScheduler = workspaceTransitionScheduler

        var initialRoot = authorizationStore.documentsURL
        var initialError: String?
        do {
            initialRoot = try authorizationStore.restore()
        } catch {
            initialError = error.localizedDescription
        }

        let terminalSession = TerminalSessionCoordinator(
            rootURL: initialRoot,
            coordinateFileAccess: initialRoot.standardizedFileURL != authorizationStore.documentsURL.standardizedFileURL
        )
        self.terminalSession = terminalSession
        let sshSession = SSHSessionController(
            secrets: secrets,
            terminalSession: terminalSession,
            clientFactory: sshClientFactory
        )
        self.sshSession = sshSession
        activeWorkspaceName = initialRoot.lastPathComponent
        authorizationErrorMessage = initialError
        terminalSession.onEditorRequested = { [weak self] url in
            self?.editorDocument = EditorDocument(url: url)
        }
        terminalSession.onDeletionConfirmationChanged = { [weak self] request in
            self?.deletionConfirmationRequest = request
        }
        terminalSession.onRemoteInput = { [weak sshSession] bytes in
            sshSession?.send(bytes)
        }
        terminalSession.onRemoteResize = { [weak sshSession] columns, rows in
            sshSession?.resize(columns: columns, rows: rows)
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-open-editor") {
            let testURL = authorizationStore.documentsURL.appendingPathComponent("UITestEditor.txt")
            if !FileManager.default.fileExists(atPath: testURL.path) {
                _ = FileManager.default.createFile(atPath: testURL.path, contents: Data())
            }
            editorDocument = EditorDocument(url: testURL)
        }
        #endif

        onHostsRequested = { [weak self] in
            self?.isShowingHosts = true
        }
    }

    func chooseExternalFolder() {
        isShowingFolderPicker = true
    }

    func completeFolderSelection(_ url: URL) {
        isShowingFolderPicker = false
        workspaceTransitionScheduler.submitNormal { [weak self] in
            await self?.selectExternalFolder(url)
        }
    }

    func useAppDocuments() {
        workspaceTransitionScheduler.submitNormal { [weak self] in
            await self?.switchToAppDocuments(clearBookmark: true)
        }
    }

    func requestHosts() {
        onHostsRequested?()
    }

    func confirmDeletion(_ request: DeletionConfirmationRequest) {
        terminalSession.confirmDeletion(request)
    }

    func cancelDeletion(_ request: DeletionConfirmationRequest) {
        terminalSession.cancelDeletion(request)
    }

    func connect(to host: SSHHost) {
        mode = .ssh
        sshSession.connect(host: host)
    }

    func didBecomeActive() {
        sshSession.scenePhaseChanged(.active)
        workspaceTransitionScheduler.submitNormal { [weak self] in
            await self?.restoreWorkspaceAfterActivation()
        }
    }

    func didEnterBackground() {
        sshSession.scenePhaseChanged(.background)
        workspaceTransitionScheduler.submitSafety { [weak self] in
            await self?.switchToAppDocuments(clearBookmark: false)
        }
    }

    func didBecomeInactive() {
        sshSession.scenePhaseChanged(.inactive)
    }

    func selectExternalFolder(_ url: URL) async {
        await terminalSession.suspendLocalInputAndDrain()
        defer { terminalSession.resumeLocalInput() }
        do {
            let root = try folderAuthorizationStore.select(url: url)
            terminalSession.installLocalRoot(
                root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = root.lastPathComponent
            authorizationErrorMessage = nil
        } catch {
            let reconciledRoot = folderAuthorizationStore.activeRootURL
            terminalSession.installLocalRoot(
                reconciledRoot,
                coordinateFileAccess: reconciledRoot.standardizedFileURL
                    != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = reconciledRoot.lastPathComponent
            authorizationErrorMessage = error.localizedDescription
        }
    }

    private func switchToAppDocuments(clearBookmark: Bool) async {
        await terminalSession.suspendLocalInputAndDrain()
        defer { terminalSession.resumeLocalInput() }
        if clearBookmark {
            folderAuthorizationStore.useAppDocuments()
        } else {
            folderAuthorizationStore.stopAccessing()
        }
        terminalSession.installLocalRoot(folderAuthorizationStore.documentsURL)
        activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
    }

    private func restoreWorkspaceAfterActivation() async {
        await terminalSession.suspendLocalInputAndDrain()
        defer { terminalSession.resumeLocalInput() }
        do {
            let root = try folderAuthorizationStore.restore()
            terminalSession.installLocalRoot(
                root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = root.lastPathComponent
        } catch {
            terminalSession.installLocalRoot(folderAuthorizationStore.documentsURL)
            activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
            authorizationErrorMessage = error.localizedDescription
        }
    }
}
