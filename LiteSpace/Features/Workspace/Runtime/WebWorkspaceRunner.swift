import Foundation
import JavaScriptCore
import LiteSpaceCore

public struct WebWorkspaceValidationReport: Sendable {
    public let generation: UInt64
    public let entrypoint: String
    public let problems: [WorkspaceProblem]
    public let source: PreviewResponseSource?

    public var passed: Bool { problems.allSatisfy { $0.severity != .error } }
}

public final class WebWorkspaceRunner: @unchecked Sendable {
    public init() {}

    @MainActor
    public func smoke(
        lease: LoopbackServerLease,
        entrypoint: String,
        timeout: Duration = .seconds(5)
    ) async -> [WorkspaceProblem] {
        let url: URL
        do {
            url = try lease.authenticatedBootstrapURL(relativePath: entrypoint)
        } catch {
            return Self.smokeProblem(
                category: .configuration,
                relativePath: entrypoint,
                message: "The private preview URL could not be prepared."
            ).map { [$0] } ?? []
        }

        let issues = await WebSmokeWebView.run(
            url: url,
            allowedPort: lease.port,
            timeout: timeout
        )
        return issues.compactMap { issue in
            let category: WorkspaceProblemCategory
            switch issue.kind {
            case .resource:
                category = .fileAccess
            case .externalNavigation, .popup, .download, .mediaPermission:
                category = .privacy
            case .pageLoad, .javascript, .promise:
                category = .runtime
            }
            return Self.smokeProblem(
                category: category,
                relativePath: entrypoint,
                line: issue.line,
                column: issue.column,
                message: issue.message
            )
        }
    }

    public static func validate(
        snapshot: WorkspaceCapturedSnapshot,
        profile: WorkspaceProfile
    ) -> WebWorkspaceValidationReport {
        let entrypoint = profile.entrypoint ?? "index.html"
        var problems: [WorkspaceProblem] = []

        guard profile.kind == .web else {
            appendProblem(
                stage: .check,
                category: .unsupported,
                relativePath: nil,
                message: "This validation path supports Web workspaces only.",
                recovery: "Select a supported Web workspace.",
                to: &problems
            )
            return WebWorkspaceValidationReport(
                generation: snapshot.snapshot.generation,
                entrypoint: entrypoint,
                problems: problems,
                source: nil
            )
        }

        guard let entryData = snapshot.content(relativePath: entrypoint),
              let entryHTML = String(data: entryData, encoding: .utf8) else {
            appendProblem(
                stage: .check,
                category: .configuration,
                relativePath: entrypoint,
                message: "The Web entrypoint is missing or is not UTF-8 HTML.",
                recovery: "Restore a UTF-8 HTML entrypoint and run Check again.",
                to: &problems
            )
            return WebWorkspaceValidationReport(
                generation: snapshot.snapshot.generation,
                entrypoint: entrypoint,
                problems: problems,
                source: nil
            )
        }

        var moduleScripts: Set<String> = []
        validateHTML(
            entryHTML,
            relativePath: entrypoint,
            snapshot: snapshot,
            moduleScripts: &moduleScripts,
            problems: &problems
        )

        for relativePath in snapshot.relativePaths where relativePath.lowercased().hasSuffix(".html")
            && relativePath != entrypoint {
            guard let data = snapshot.content(relativePath: relativePath),
                  let html = String(data: data, encoding: .utf8) else {
                appendProblem(
                    stage: .check,
                    category: .syntax,
                    relativePath: relativePath,
                    message: "A Web source file is not valid UTF-8.",
                    recovery: "Save the source as UTF-8 and run Check again.",
                    to: &problems
                )
                continue
            }
            validateHTML(
                html,
                relativePath: relativePath,
                snapshot: snapshot,
                moduleScripts: &moduleScripts,
                problems: &problems
            )
        }

        for relativePath in snapshot.relativePaths where relativePath.lowercased().hasSuffix(".css") {
            guard let data = snapshot.content(relativePath: relativePath),
                  let css = String(data: data, encoding: .utf8) else {
                appendProblem(
                    stage: .check,
                    category: .syntax,
                    relativePath: relativePath,
                    message: "A stylesheet is not valid UTF-8.",
                    recovery: "Save the stylesheet as UTF-8 and run Check again.",
                    to: &problems
                )
                continue
            }
            for reference in cssReferences(in: css) {
                validate(
                    reference: reference,
                    from: relativePath,
                    snapshot: snapshot,
                    moduleScripts: &moduleScripts,
                    problems: &problems
                )
            }
        }

        for relativePath in snapshot.relativePaths {
            let lowercase = relativePath.lowercased()
            guard lowercase.hasSuffix(".js"), !moduleScripts.contains(relativePath) else { continue }
            guard let data = snapshot.content(relativePath: relativePath),
                  let source = String(data: data, encoding: .utf8),
                  parsesClassicJavaScript(source) else {
                appendProblem(
                    stage: .check,
                    category: .syntax,
                    relativePath: relativePath,
                    message: "Classic JavaScript syntax could not be parsed.",
                    recovery: "Correct the script syntax and run Check again.",
                    to: &problems
                )
                continue
            }
        }

        let source = problems.contains(where: { $0.severity == .error })
            ? nil
            : makePreviewSource(snapshot: snapshot, entrypoint: entrypoint)
        return WebWorkspaceValidationReport(
            generation: snapshot.snapshot.generation,
            entrypoint: entrypoint,
            problems: Array(problems.prefix(100)),
            source: source
        )
    }

    private static func validateHTML(
        _ html: String,
        relativePath: String,
        snapshot: WorkspaceCapturedSnapshot,
        moduleScripts: inout Set<String>,
        problems: inout [WorkspaceProblem]
    ) {
        for reference in htmlReferences(in: html) {
            validate(
                reference: reference,
                from: relativePath,
                snapshot: snapshot,
                moduleScripts: &moduleScripts,
                problems: &problems
            )
        }

        for script in scriptTags(in: html) {
            let type = attribute(named: "type", in: script.attributes)?.lowercased()
            let isModule = type == "module"
            if let sourceReference = attribute(named: "src", in: script.attributes),
               case let .local(path) = resolve(reference: sourceReference, from: relativePath),
               isModule {
                moduleScripts.insert(path)
            }
            guard !isModule, type == nil || type == "text/javascript" || type == "application/javascript" else {
                continue
            }
            guard attribute(named: "src", in: script.attributes) == nil,
                  !script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if !parsesClassicJavaScript(script.body) {
                appendProblem(
                    stage: .check,
                    category: .syntax,
                    relativePath: relativePath,
                    message: "Inline classic JavaScript syntax could not be parsed.",
                    recovery: "Correct the script syntax and run Check again.",
                    to: &problems
                )
            }
        }
    }

    private enum ResolvedReference {
        case ignored
        case external
        case invalid
        case local(path: String)
    }

    private static func validate(
        reference: String,
        from sourcePath: String,
        snapshot: WorkspaceCapturedSnapshot,
        moduleScripts: inout Set<String>,
        problems: inout [WorkspaceProblem]
    ) {
        switch resolve(reference: reference, from: sourcePath) {
        case .ignored:
            break
        case .external:
            appendProblem(
                stage: .check,
                category: .privacy,
                relativePath: sourcePath,
                message: "External Web resources are not allowed.",
                recovery: "Store the required resource inside the workspace.",
                to: &problems
            )
        case .invalid:
            appendProblem(
                stage: .check,
                category: .fileAccess,
                relativePath: sourcePath,
                message: "A referenced resource escapes the workspace or has an invalid path.",
                recovery: "Use a root-contained relative resource path.",
                to: &problems
            )
        case let .local(path):
            guard isAllowedResource(path: path) else {
                appendProblem(
                    stage: .check,
                    category: .unsupported,
                    relativePath: sourcePath,
                    message: "A referenced Web resource type is not supported.",
                    recovery: "Use a reviewed static Web resource type.",
                    to: &problems
                )
                return
            }
            guard snapshot.content(relativePath: path) != nil else {
                appendProblem(
                    stage: .check,
                    category: .configuration,
                    relativePath: sourcePath,
                    message: "A referenced local Web resource is missing.",
                    recovery: "Restore the resource and run Check again.",
                    to: &problems
                )
                return
            }
        }
    }

    private static func resolve(reference: String, from sourcePath: String) -> ResolvedReference {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return .ignored }
        let lowercase = trimmed.lowercased()
        if lowercase.hasPrefix("data:") { return .ignored }
        if lowercase.hasPrefix("http:") || lowercase.hasPrefix("https:")
            || lowercase.hasPrefix("//") || lowercase.hasPrefix("javascript:")
            || lowercase.hasPrefix("mailto:") || lowercase.hasPrefix("tel:")
            || lowercase.hasPrefix("blob:") {
            return .external
        }
        if let schemeRange = trimmed.range(of: ":"),
           !trimmed[..<schemeRange.lowerBound].contains("/") {
            return .external
        }

        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(withoutQuery).removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("\0") else {
            return .invalid
        }

        var components: [String] = decoded.hasPrefix("/")
            ? []
            : Array(sourcePath.split(separator: "/").dropLast()).map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return .invalid }
                components.removeLast()
            default:
                guard !component.hasPrefix(".") else { return .invalid }
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return .invalid }
        let path = components.joined(separator: "/")
        return WorkspaceRelativePathPolicy.isValidFilePath(path) ? .local(path: path) : .invalid
    }

    private static func makePreviewSource(
        snapshot: WorkspaceCapturedSnapshot,
        entrypoint: String
    ) -> PreviewResponseSource {
        var files: [String: PreviewResponse] = [:]
        for relativePath in snapshot.relativePaths where isAllowedResource(path: relativePath) {
            guard let body = snapshot.content(relativePath: relativePath) else { continue }
            files[relativePath] = PreviewResponse(
                status: 200,
                headers: [
                    "Content-Type": contentType(for: relativePath),
                    "Content-Security-Policy": "default-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
                    "Cache-Control": "no-store"
                ],
                body: body
            )
        }
        files[""] = files[entrypoint]
        return .staticFiles(files)
    }

    private static func parsesClassicJavaScript(_ source: String) -> Bool {
        guard let encoded = try? JSONEncoder().encode(source),
              let literal = String(data: encoded, encoding: .utf8),
              let context = JSContext() else { return false }
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        _ = context.evaluateScript("new Function(\(literal))")
        return exception == nil
    }

    private struct ScriptTag {
        let attributes: String
        let body: String
    }

    private static func scriptTags(in html: String) -> [ScriptTag] {
        matches(pattern: #"(?is)<script\b([^>]*)>(.*?)</script\s*>"#, in: html).compactMap { match in
            guard match.count == 3 else { return nil }
            return ScriptTag(attributes: match[1], body: match[2])
        }
    }

    private static func htmlReferences(in html: String) -> [String] {
        matches(
            pattern: #"(?is)\b(?:src|href|poster)\s*=\s*([\"'])(.*?)\1"#,
            in: html
        ).compactMap { $0.count == 3 ? $0[2] : nil }
    }

    private static func cssReferences(in css: String) -> [String] {
        let urls = matches(
            pattern: #"(?is)url\(\s*([\"']?)(.*?)\1\s*\)"#,
            in: css
        ).compactMap { $0.count == 3 ? $0[2] : nil }
        let imports = matches(
            pattern: #"(?is)@import\s+([\"'])(.*?)\1"#,
            in: css
        ).compactMap { $0.count == 3 ? $0[2] : nil }
        return urls + imports
    }

    private static func attribute(named name: String, in attributes: String) -> String? {
        matches(
            pattern: "(?is)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\\\"'])(.*?)\\1",
            in: attributes
        ).first.flatMap { $0.count == 3 ? $0[2] : nil }
    }

    private static func matches(pattern: String, in source: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let matchRange = match.range(at: index)
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: source) else { return "" }
                return String(source[range])
            }
        }
    }

    private static func isAllowedResource(path: String) -> Bool {
        guard let fileExtension = path.split(separator: ".").last?.lowercased() else { return false }
        return [
            "html", "htm", "css", "js", "mjs", "json", "txt", "svg",
            "png", "jpg", "jpeg", "gif", "webp", "ico", "woff", "woff2"
        ].contains(fileExtension)
    }

    private static func contentType(for path: String) -> String {
        switch path.split(separator: ".").last?.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "text/plain; charset=utf-8"
        }
    }

    private static func appendProblem(
        stage: WorkspaceStage,
        category: WorkspaceProblemCategory,
        relativePath: String?,
        message: String,
        recovery: String,
        to problems: inout [WorkspaceProblem]
    ) {
        guard problems.count < 100,
              let problem = try? WorkspaceProblem(
                stage: stage,
                severity: .error,
                category: category,
                relativePath: relativePath,
                message: message,
                recoveryAction: recovery
              ) else { return }
        problems.append(problem)
    }

    private static func smokeProblem(
        category: WorkspaceProblemCategory,
        relativePath: String,
        line: Int? = nil,
        column: Int? = nil,
        message: String
    ) -> WorkspaceProblem? {
        try? WorkspaceProblem(
            stage: .test,
            severity: .error,
            category: category,
            relativePath: relativePath,
            line: line,
            column: column,
            message: message,
            recoveryAction: "Correct the Web source and run Test again."
        )
    }
}
