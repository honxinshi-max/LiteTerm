public enum WorkspaceRelativePathPolicy {
    public static func isValidFilePath(_ value: String) -> Bool {
        isValidRelativePath(value, allowEmpty: false, rejectHTTPDelimiters: false)
    }

    public static func isValidHealthPath(_ value: String) -> Bool {
        isValidRelativePath(value, allowEmpty: true, rejectHTTPDelimiters: true)
    }

    private static func isValidRelativePath(
        _ value: String,
        allowEmpty: Bool,
        rejectHTTPDelimiters: Bool
    ) -> Bool {
        if value.isEmpty {
            return allowEmpty
        }
        guard
            !value.hasPrefix("/"),
            !value.contains("\\"),
            !(rejectHTTPDelimiters && value.contains(where: { ":?#".contains($0) }))
        else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
