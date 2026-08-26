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
            } else {
                workspaceTransitionScheduler.submitSafety { [weak self] in
                    await self?.workspaceController.stopAndInvalidate()
                }
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
    let workspaceController: WorkspaceController
    private let workspaceTransitionScheduler: WorkspaceTransitionScheduler

    var onHostsRequested: (() -> Void)?
    var canRequestHosts: Bool { onHostsRequested != nil }
    var activeWorkspaceURL: URL { folderAuthorizationStore.activeRootURL }

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
        #if DEBUG
        let isWorkspaceUITest = ProcessInfo.processInfo.arguments.contains("-ui-testing-workspace")
        #else
        let isWorkspaceUITest = false
        #endif
        if isWorkspaceUITest {
            authorizationStore.useAppDocuments()
        } else {
            do {
                initialRoot = try authorizationStore.restore()
            } catch {
                initialError = error.localizedDescription
            }
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
        let workspaceController = WorkspaceController(rootURL: initialRoot)
        self.workspaceController = workspaceController
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
        terminalSession.onWorkspaceAction = { [weak workspaceController] action in
            workspaceController?.handleShellAction(action)
        }
        workspaceController.onTerminalSummary = { [weak terminalSession] lines in
            terminalSession?.presentWorkspaceSummary(lines)
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-workspace") {
            let fixtureURL = authorizationStore.documentsURL.appendingPathComponent("index.html")
            if !FileManager.default.fileExists(atPath: fixtureURL.path) {
                try? Data("<h1>LiteTerm workspace</h1>".utf8).write(
                    to: fixtureURL,
                    options: .atomic
                )
            }
        }
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

    func workspaceSourceDidChange() {
        workspaceTransitionScheduler.submitSafety { [weak self] in
            await self?.workspaceController.sourceDidChange()
        }
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
            await workspaceController.installRoot(root)
            terminalSession.installLocalRoot(
                root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = root.lastPathComponent
            authorizationErrorMessage = nil
        } catch {
            let reconciledRoot = folderAuthorizationStore.activeRootURL
            await workspaceController.installRoot(reconciledRoot)
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
        await workspaceController.installRoot(folderAuthorizationStore.documentsURL)
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
            await workspaceController.installRoot(root)
            terminalSession.installLocalRoot(
                root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = root.lastPathComponent
        } catch {
            await workspaceController.installRoot(folderAuthorizationStore.documentsURL)
            terminalSession.installLocalRoot(folderAuthorizationStore.documentsURL)
            activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
            authorizationErrorMessage = error.localizedDescription
        }
    }
}
