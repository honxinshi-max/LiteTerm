public struct WorkspaceInventoryEntry: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let isDirectory: Bool
    public let isRegularFile: Bool
    public let isSymbolicLink: Bool
    public let symbolicLinkTargetIsInsideRoot: Bool

    public init(
        relativePath: String,
        byteCount: Int,
        isDirectory: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool,
        symbolicLinkTargetIsInsideRoot: Bool
    ) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.symbolicLinkTargetIsInsideRoot = symbolicLinkTargetIsInsideRoot
    }
}

public enum WorkspaceInventoryExclusionReason: String, Hashable, Sendable {
    case hidden
    case generatedOrCache
    case credentialLike
    case binary
    case symbolicLinkEscape
    case notRegularFile
}

public struct WorkspaceInventoryExclusion: Equatable, Sendable {
    public let relativePath: String
    public let reason: WorkspaceInventoryExclusionReason

    public init(relativePath: String, reason: WorkspaceInventoryExclusionReason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public enum WorkspaceInventoryViolation: Equatable, Hashable, Sendable {
    case invalidRelativePath
    case duplicateRelativePath
    case invalidByteCount
    case entryCountExceeded(limit: Int)
    case fileBytesExceeded(limit: Int)
    case totalSourceBytesExceeded(limit: Int)
}

public struct WorkspaceInventoryEvaluation: Equatable, Sendable {
    public let acceptedFiles: [WorkspaceInventoryEntry]
    public let exclusions: [WorkspaceInventoryExclusion]
    public let violations: [WorkspaceInventoryViolation]

    public init(
        acceptedFiles: [WorkspaceInventoryEntry],
        exclusions: [WorkspaceInventoryExclusion],
        violations: [WorkspaceInventoryViolation]
    ) {
        self.acceptedFiles = acceptedFiles
        self.exclusions = exclusions
        self.violations = violations
    }
}

public struct WorkspaceInventoryPolicy: Sendable {
    public static let maximumEntryCount = 1_000
    public static let maximumSourceBytes = 20 * 1_024 * 1_024
    public static let maximumFileBytes = 5 * 1_024 * 1_024

    private static let generatedComponents: Set<String> = [
        "node_modules", "__pycache__", "build", "dist", "deriveddata",
        "venv", "vendor", "pods", "packages"
    ]
    private static let credentialStems: Set<String> = [
        "credential", "credentials", "secret", "secrets", "token", "tokens",
        "private_key", "private-key", "id_rsa", "id_ed25519"
    ]
    private static let credentialExtensions: Set<String> = [
        "key", "pem", "p12", "pfx", "mobileprovision"
    ]
    private static let binaryExtensions: Set<String> = [
        "a", "app", "dylib", "framework", "gif", "gz", "heic", "ico",
        "ipa", "jpeg", "jpg", "mov", "mp3", "mp4", "o", "pdf", "png",
        "pyc", "so", "tar", "tgz", "wasm", "webp", "xcarchive",
        "xcframework", "zip"
    ]

    public init() {}

    public func evaluate(_ entries: [WorkspaceInventoryEntry]) -> WorkspaceInventoryEvaluation {
        var accepted: [WorkspaceInventoryEntry] = []
        var exclusions: [WorkspaceInventoryExclusion] = []
        var violations: Set<WorkspaceInventoryViolation> = []
        var seenPaths: Set<String> = []

        if entries.count > Self.maximumEntryCount {
            violations.insert(.entryCountExceeded(limit: Self.maximumEntryCount))
        }

        for entry in entries {
            guard isValid(relativePath: entry.relativePath) else {
                violations.insert(.invalidRelativePath)
                continue
            }
            guard seenPaths.insert(entry.relativePath).inserted else {
                violations.insert(.duplicateRelativePath)
                continue
            }
            guard entry.byteCount >= 0 else {
                violations.insert(.invalidByteCount)
                continue
            }
            guard !entry.isDirectory else {
                continue
            }
            if entry.isSymbolicLink && !entry.symbolicLinkTargetIsInsideRoot {
                exclusions.append(exclusion(entry, .symbolicLinkEscape))
                continue
            }
            guard entry.isRegularFile else {
                exclusions.append(exclusion(entry, .notRegularFile))
                continue
            }
            if let reason = exclusionReason(for: entry.relativePath) {
                exclusions.append(exclusion(entry, reason))
                continue
            }
            if entry.byteCount > Self.maximumFileBytes {
                violations.insert(.fileBytesExceeded(limit: Self.maximumFileBytes))
                continue
            }
            accepted.append(entry)
        }

        let totalBytes = accepted.reduce(0) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
            return overflow ? Int.max : sum
        }
        if totalBytes > Self.maximumSourceBytes {
            violations.insert(.totalSourceBytesExceeded(limit: Self.maximumSourceBytes))
        }

        return WorkspaceInventoryEvaluation(
            acceptedFiles: accepted.sorted { $0.relativePath < $1.relativePath },
            exclusions: exclusions.sorted { $0.relativePath < $1.relativePath },
            violations: violations.sorted(by: violationOrder)
        )
    }

    private func isValid(relativePath: String) -> Bool {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\\")
        else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func exclusionReason(for relativePath: String) -> WorkspaceInventoryExclusionReason? {
        let components = relativePath.split(separator: "/").map { String($0).lowercased() }
        if components.contains(where: { $0.hasPrefix(".") }) {
            return .hidden
        }
        if components.contains(where: Self.generatedComponents.contains) {
            return .generatedOrCache
        }

        guard let filename = components.last else { return nil }
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let stem = parts.first ?? filename
        let fileExtension = parts.count > 1 ? parts.last ?? "" : ""
        if Self.credentialStems.contains(stem)
            || Self.credentialStems.contains(filename)
            || stem.hasPrefix("id_")
            || Self.credentialExtensions.contains(fileExtension) {
            return .credentialLike
        }
        if Self.binaryExtensions.contains(fileExtension) {
            return .binary
        }
        return nil
    }

    private func exclusion(
        _ entry: WorkspaceInventoryEntry,
        _ reason: WorkspaceInventoryExclusionReason
    ) -> WorkspaceInventoryExclusion {
        WorkspaceInventoryExclusion(relativePath: entry.relativePath, reason: reason)
    }

    private func violationOrder(
        _ lhs: WorkspaceInventoryViolation,
        _ rhs: WorkspaceInventoryViolation
    ) -> Bool {
        String(describing: lhs) < String(describing: rhs)
    }
}
