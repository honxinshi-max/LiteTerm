import LiteTermCore
import LiteTermPythonBridge

public enum PythonProblemMapper {
    public static func unavailable() -> WorkspaceProblem? {
        try? WorkspaceProblem(
            stage: .unsupported,
            severity: .error,
            category: .unsupported,
            message: "The reviewed embedded Python runtime is unavailable on this build.",
            recoveryAction: "Install and verify the pinned iOS Python artifact before enabling Run."
        )
    }

    public static func map(
        _ code: LTPythonErrorCode,
        stage: WorkspaceStage,
        relativePath: String? = nil,
        line: Int? = nil,
        column: Int? = nil
    ) -> WorkspaceProblem? {
        let category: WorkspaceProblemCategory
        let message: String
        switch code {
        case LT_PYTHON_ERROR_COMPILE:
            category = .syntax
            message = "Python source compilation failed."
        case LT_PYTHON_ERROR_TEST:
            category = .testFailure
            message = "Python tests failed."
        case LT_PYTHON_ERROR_POLICY_DENIED:
            category = .privacy
            message = "Python attempted an unavailable capability."
        case LT_PYTHON_ERROR_DEADLINE, LT_PYTHON_ERROR_CANCELLED:
            category = .resource
            message = "Python execution exceeded its reviewed resource boundary."
        case LT_PYTHON_ERROR_RUNTIME_UNAVAILABLE:
            return unavailable()
        default:
            category = .runtime
            message = "The embedded Python runtime failed."
        }
        return try? WorkspaceProblem(
            stage: stage,
            severity: .error,
            category: category,
            relativePath: relativePath,
            line: line,
            column: column,
            message: message,
            recoveryAction: "Review the Python Problems entry and run the gate again."
        )
    }
}
