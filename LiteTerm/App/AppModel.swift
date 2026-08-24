import Combine
import Foundation

struct EditorDocument: Identifiable {
    let url: URL
    var id: URL { url }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: TerminalMode = .local {
        didSet { terminalSession.setMode(mode) }
    }
    @Published var isShowingFolderPicker = false
    @Published var editorDocument: EditorDocument?
    @Published var authorizationErrorMessage: String?
    @Published private(set) var activeWorkspaceName: String

    let folderAuthorizationStore: FolderAuthorizationStore
    let terminalSession: TerminalSessionCoordinator

    var onHostsRequested: (() -> Void)?
    var canRequestHosts: Bool { onHostsRequested != nil }

    init() {
        let authorizationStore = FolderAuthorizationStore()
        folderAuthorizationStore = authorizationStore

        var initialRoot = authorizationStore.documentsURL
        var initialError: String?
        do {
            initialRoot = try authorizationStore.restore()
        } catch {
            initialError = error.localizedDescription
        }

        terminalSession = TerminalSessionCoordinator(
            rootURL: initialRoot,
            coordinateFileAccess: initialRoot.standardizedFileURL != authorizationStore.documentsURL.standardizedFileURL
        )
        activeWorkspaceName = initialRoot.lastPathComponent
        authorizationErrorMessage = initialError
        terminalSession.onEditorRequested = { [weak self] url in
            self?.editorDocument = EditorDocument(url: url)
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
    }

    func chooseExternalFolder() {
        isShowingFolderPicker = true
    }

    func completeFolderSelection(_ url: URL) {
        isShowingFolderPicker = false
        do {
            let root = try folderAuthorizationStore.select(url: url)
            activeWorkspaceName = root.lastPathComponent
            terminalSession.replaceLocalRoot(
                with: root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
        } catch {
            authorizationErrorMessage = error.localizedDescription
        }
    }

    func useAppDocuments() {
        folderAuthorizationStore.useAppDocuments()
        activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
        terminalSession.replaceLocalRoot(with: folderAuthorizationStore.documentsURL)
    }

    func requestHosts() {
        onHostsRequested?()
    }

    func didBecomeActive() {
        do {
            let root = try folderAuthorizationStore.restore()
            activeWorkspaceName = root.lastPathComponent
            terminalSession.replaceLocalRoot(
                with: root,
                coordinateFileAccess: root.standardizedFileURL != folderAuthorizationStore.documentsURL.standardizedFileURL
            )
        } catch {
            activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
            terminalSession.replaceLocalRoot(with: folderAuthorizationStore.documentsURL)
            authorizationErrorMessage = error.localizedDescription
        }
    }

    func didEnterBackground() {
        folderAuthorizationStore.stopAccessing()
        activeWorkspaceName = folderAuthorizationStore.documentsURL.lastPathComponent
        terminalSession.replaceLocalRoot(with: folderAuthorizationStore.documentsURL)
    }
}
