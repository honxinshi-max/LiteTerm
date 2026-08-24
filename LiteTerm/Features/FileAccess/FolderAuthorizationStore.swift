import Combine
import Foundation

enum FolderAuthorizationError: LocalizedError {
    case notDirectory
    case accessDenied
    case staleBookmark

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return "The selected item is not a folder."
        case .accessDenied:
            return "LiteTerm could not access the selected folder."
        case .staleBookmark:
            return "Folder authorization expired. Choose the folder again."
        }
    }
}

@MainActor
final class FolderAuthorizationStore: ObservableObject {
    @Published private(set) var activeRootURL: URL
    @Published private(set) var needsReauthorization = false

    let documentsURL: URL

    private let defaults: UserDefaults
    private let bookmarkKey = "LiteTerm.activeExternalFolderBookmark"
    private var externalRootURL: URL?
    private var isAccessingExternalRoot = false

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        activeRootURL = documentsURL
        self.defaults = defaults
    }

    @discardableResult
    func select(url: URL) throws -> URL {
        if url.standardizedFileURL == documentsURL.standardizedFileURL {
            useAppDocuments()
            return documentsURL
        }

        let previousURL = externalRootURL
        stopCurrentExternalAccess()
        guard url.startAccessingSecurityScopedResource() else {
            restoreAccessIfPossible(to: previousURL)
            throw FolderAuthorizationError.accessDenied
        }

        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw FolderAuthorizationError.notDirectory
            }
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )

            isAccessingExternalRoot = true
            externalRootURL = url
            activeRootURL = url
            needsReauthorization = false
            defaults.set(bookmark, forKey: bookmarkKey)
            return url
        } catch {
            url.stopAccessingSecurityScopedResource()
            restoreAccessIfPossible(to: previousURL)
            throw error
        }
    }

    @discardableResult
    func restore() throws -> URL {
        stopCurrentExternalAccess()
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            activeRootURL = documentsURL
            needsReauthorization = false
            return documentsURL
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            activeRootURL = documentsURL
            needsReauthorization = true
            throw error
        }
        guard !isStale else {
            defaults.removeObject(forKey: bookmarkKey)
            activeRootURL = documentsURL
            needsReauthorization = true
            throw FolderAuthorizationError.staleBookmark
        }
        guard url.startAccessingSecurityScopedResource() else {
            activeRootURL = documentsURL
            needsReauthorization = true
            throw FolderAuthorizationError.accessDenied
        }

        externalRootURL = url
        isAccessingExternalRoot = true
        activeRootURL = url
        needsReauthorization = false
        return url
    }

    func stopAccessing() {
        stopCurrentExternalAccess()
        activeRootURL = documentsURL
    }

    func useAppDocuments() {
        stopCurrentExternalAccess()
        defaults.removeObject(forKey: bookmarkKey)
        needsReauthorization = false
        activeRootURL = documentsURL
    }

    private func stopCurrentExternalAccess() {
        if isAccessingExternalRoot, let externalRootURL {
            externalRootURL.stopAccessingSecurityScopedResource()
        }
        isAccessingExternalRoot = false
        externalRootURL = nil
    }

    private func restoreAccessIfPossible(to url: URL?) {
        guard let url, url.startAccessingSecurityScopedResource() else {
            activeRootURL = documentsURL
            return
        }
        externalRootURL = url
        isAccessingExternalRoot = true
        activeRootURL = url
        needsReauthorization = false
    }
}
