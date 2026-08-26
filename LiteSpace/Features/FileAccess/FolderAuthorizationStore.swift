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
            return "LiteSpace could not access the selected folder."
        case .staleBookmark:
            return "Folder authorization expired. Choose the folder again."
        }
    }
}

@MainActor
struct FolderAuthorizationDependencies {
    let startAccessing: @MainActor (URL) -> Bool
    let stopAccessing: @MainActor (URL) -> Void
    let isDirectory: @MainActor (URL) throws -> Bool
    let makeBookmark: @MainActor (URL) throws -> Data

    static let live = FolderAuthorizationDependencies(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        isDirectory: { url in
            try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        },
        makeBookmark: { url in
            try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
        }
    )
}

@MainActor
final class FolderAuthorizationStore: ObservableObject {
    @Published private(set) var activeRootURL: URL
    @Published private(set) var needsReauthorization = false

    let documentsURL: URL

    private let defaults: UserDefaults
    private let resourceAccess: FolderAuthorizationDependencies
    private let bookmarkKey = "LiteSpace.activeExternalFolderBookmark"
    private var externalRootURL: URL?
    private var isAccessingExternalRoot = false

    init(
        fileManager: FileManager = .default,
        documentsURL: URL? = nil,
        defaults: UserDefaults = .standard,
        resourceAccess: FolderAuthorizationDependencies = .live
    ) {
        let resolvedDocumentsURL = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documentsURL = resolvedDocumentsURL
        activeRootURL = resolvedDocumentsURL
        self.defaults = defaults
        self.resourceAccess = resourceAccess
    }

    @discardableResult
    func select(url: URL) throws -> URL {
        if url.standardizedFileURL == documentsURL.standardizedFileURL {
            useAppDocuments()
            return documentsURL
        }

        let previousURL = externalRootURL
        stopCurrentExternalAccess()
        guard resourceAccess.startAccessing(url) else {
            restoreAccessIfPossible(to: previousURL)
            throw FolderAuthorizationError.accessDenied
        }

        do {
            guard try resourceAccess.isDirectory(url) else {
                throw FolderAuthorizationError.notDirectory
            }
            let bookmark = try resourceAccess.makeBookmark(url)

            isAccessingExternalRoot = true
            externalRootURL = url
            activeRootURL = url
            needsReauthorization = false
            defaults.set(bookmark, forKey: bookmarkKey)
            return url
        } catch {
            resourceAccess.stopAccessing(url)
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
        guard resourceAccess.startAccessing(url) else {
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
            resourceAccess.stopAccessing(externalRootURL)
        }
        isAccessingExternalRoot = false
        externalRootURL = nil
    }

    private func restoreAccessIfPossible(to url: URL?) {
        guard let url, resourceAccess.startAccessing(url) else {
            activeRootURL = documentsURL
            needsReauthorization = url != nil
            return
        }
        externalRootURL = url
        isAccessingExternalRoot = true
        activeRootURL = url
        needsReauthorization = false
    }
}
