public struct WorkspaceClassifier: Sendable {
    public init() {}

    public func classify(relativePaths: [String]) -> WorkspaceClassification {
        var indicators: Set<WorkspaceIndicator> = []

        for relativePath in relativePaths {
            let filename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
            let lowercaseFilename = filename.lowercased()

            switch filename {
            case "Package.swift":
                indicators.insert(.packageSwift)
            case "pyproject.toml":
                indicators.insert(.pyproject)
            case "requirements.txt":
                indicators.insert(.requirements)
            case "index.html":
                indicators.insert(.indexHTML)
            case "package.json":
                indicators.insert(.packageJSON)
            default:
                if lowercaseFilename.hasSuffix(".swift") {
                    indicators.insert(.swiftSource)
                } else if lowercaseFilename.hasSuffix(".py") {
                    indicators.insert(.pythonSource)
                }
            }
        }

        var supported: Set<WorkspaceKind> = []
        if !indicators.isDisjoint(with: [.packageSwift, .swiftSource]) {
            supported.insert(.swift)
        }
        if !indicators.isDisjoint(with: [.pyproject, .requirements, .pythonSource]) {
            supported.insert(.python)
        }
        if indicators.contains(.indexHTML) {
            supported.insert(.web)
        }

        var candidates = supported
        if indicators.contains(.packageJSON) {
            candidates.insert(.nodeRequired)
        }

        let kind: WorkspaceKind
        if supported.count > 1 {
            kind = .ambiguous
        } else if let supportedKind = supported.first {
            kind = supportedKind
        } else if indicators.contains(.packageJSON) {
            kind = .nodeRequired
        } else {
            kind = .unsupported
        }

        return WorkspaceClassification(
            kind: kind,
            candidates: candidates,
            indicators: indicators
        )
    }
}
