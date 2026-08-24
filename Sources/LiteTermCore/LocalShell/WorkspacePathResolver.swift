import Foundation

public enum WorkspacePathResolverError: Error, Equatable, Sendable {
    case outsideWorkspace
    case unresolvablePath
}

public struct WorkspacePathResolver: Sendable {
    public let rootURL: URL
    public let currentDirectoryURL: URL
    private let pathInspector: any WorkspacePathInspecting

    public init(
        rootURL: URL,
        currentDirectoryURL: URL,
        pathInspector: (any WorkspacePathInspecting)? = nil
    ) {
        let inspector = pathInspector ?? LocalFileSystem(rootURL: rootURL)
        self.pathInspector = inspector
        self.rootURL = (try? Self.canonicalURL(rootURL, pathInspector: inspector)) ?? rootURL.standardizedFileURL
        self.currentDirectoryURL = (try? Self.canonicalURL(currentDirectoryURL, pathInspector: inspector)) ?? currentDirectoryURL.standardizedFileURL
    }

    public func resolve(_ userPath: String) throws -> URL {
        let candidate: URL
        if userPath.hasPrefix("/") {
            let virtualPath = String(userPath.drop(while: { $0 == "/" }))
            candidate = rootURL.appendingPathComponent(virtualPath)
        } else {
            candidate = currentDirectoryURL.appendingPathComponent(userPath)
        }

        let resolved = try Self.canonicalURL(candidate, pathInspector: pathInspector)
        guard Self.isContained(resolved, by: rootURL) else {
            throw WorkspacePathResolverError.outsideWorkspace
        }
        return resolved
    }

    public func displayPath(for url: URL) -> String {
        guard let resolved = try? Self.canonicalURL(url, pathInspector: pathInspector) else {
            return "/"
        }
        guard Self.isContained(resolved, by: rootURL) else {
            return "/"
        }

        let relativeComponents = Array(resolved.pathComponents.dropFirst(rootURL.pathComponents.count))
        return relativeComponents.isEmpty ? "/" : "/" + relativeComponents.joined(separator: "/")
    }

    private static func canonicalURL(
        _ url: URL,
        pathInspector: any WorkspacePathInspecting
    ) throws -> URL {
        var resolvedComponents: [String] = []
        var pendingComponents = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var symlinkCount = 0

        while !pendingComponents.isEmpty {
            let component = pendingComponents.removeFirst()
            switch component {
            case "", ".":
                continue
            case "..":
                if !resolvedComponents.isEmpty {
                    resolvedComponents.removeLast()
                }
            default:
                let candidatePath = "/" + (resolvedComponents + [component]).joined(separator: "/")
                let candidateURL = URL(fileURLWithPath: candidatePath)
                if let destination = try pathInspector.symbolicLinkDestination(at: candidateURL) {
                    symlinkCount += 1
                    guard symlinkCount <= 40 else {
                        throw WorkspacePathResolverError.unresolvablePath
                    }

                    if destination.hasPrefix("/") {
                        resolvedComponents = []
                    }
                    let destinationComponents = destination.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    pendingComponents = destinationComponents + pendingComponents
                } else {
                    resolvedComponents.append(component)
                }
            }
        }

        return URL(fileURLWithPath: "/" + resolvedComponents.joined(separator: "/"))
    }

    private static func isContained(_ url: URL, by root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }
}
