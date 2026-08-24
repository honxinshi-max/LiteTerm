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
    @Published var authorizationErrorMessage: String?
    @Published private(set) var activeWorkspaceName: String

    let folderAuthorizationStore: FolderAuthorizationStore
    let hostStore: HostStore
    let terminalSession: TerminalSessionCoordinator
    let sshSession: SSHSessionController
    private let workspaceTransitionQueue = LocalOperationQueue()

    var onHostsRequested: (() -> Void)?
    var canRequestHosts: Bool { onHostsRequested != nil }

    init() {
        let authorizationStore = FolderAuthorizationStore()
        let secrets = KeychainStore()
        folderAuthorizationStore = authorizationStore
        hostStore = HostStore(secrets: secrets)

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
            terminalSession: terminalSession
        )
        self.sshSession = sshSession
        activeWorkspaceName = initialRoot.lastPathComponent
        authorizationErrorMessage = initialError
        terminalSession.onEditorRequested = { [weak self] url in
            self?.editorDocument = EditorDocument(url: url)
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
        workspaceTransitionQueue.enqueue { [weak self] in
            await self?.selectExternalFolder(url)
        }
    }

    func useAppDocuments() {
        workspaceTransitionQueue.enqueue { [weak self] in
            await self?.switchToAppDocuments(clearBookmark: true)
        }
    }

    func requestHosts() {
        onHostsRequested?()
    }

    func connect(to host: SSHHost) {
        mode = .ssh
        sshSession.connect(host: host)
    }

    func didBecomeActive() {
        sshSession.scenePhaseChanged(.active)
        workspaceTransitionQueue.enqueue { [weak self] in
            await self?.restoreWorkspaceAfterActivation()
        }
    }

    func didEnterBackground() {
        sshSession.scenePhaseChanged(.background)
        workspaceTransitionQueue.enqueue { [weak self] in
            await self?.switchToAppDocuments(clearBookmark: false)
        }
    }

    func didBecomeInactive() {
        sshSession.scenePhaseChanged(.inactive)
    }

    private func selectExternalFolder(_ url: URL) async {
        await terminalSession.suspendLocalInputAndDrain()
        do {
            let root = try folderAuthorizationStore.select(url: url)
            terminalSession.installLocalRoot(
                root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
            activeWorkspaceName = root.lastPathComponent
        } catch {
            authorizationErrorMessage = error.localizedDescription
        }
        terminalSession.resumeLocalInput()
    }

    private func switchToAppDocuments(clearBookmark: Bool) async {
        await terminalSession.suspendLocalInputAndDrain()
        if clearBookmark {
            folderAuthorizationStore.useAppDocuments()
        } else {
            folderAuthorizationStore.stopAccessing()
        }
        terminalSession.installLocalRoot(folderAuthorizationStore.documentsURL)
        activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
        terminalSession.resumeLocalInput()
    }

    private func restoreWorkspaceAfterActivation() async {
        await terminalSession.suspendLocalInputAndDrain()
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
        terminalSession.resumeLocalInput()
    }
}
