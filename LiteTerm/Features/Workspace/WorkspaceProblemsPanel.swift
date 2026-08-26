import LiteTermCore
import SwiftUI

struct WorkspaceProblemsPanel: View {
    let problems: [WorkspaceProblem]

    var body: some View {
        Group {
            if problems.isEmpty {
                ContentUnavailableView(
                    "No workspace problems",
                    systemImage: "checkmark.circle",
                    description: Text("Run Check or Test to refresh diagnostics.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(problems) { problem in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(
                                        problem.category.rawValue,
                                        systemImage: problem.severity == .error
                                            ? "xmark.octagon.fill"
                                            : "exclamationmark.triangle.fill"
                                    )
                                    .foregroundStyle(problem.severity == .error ? .red : .orange)
                                    Spacer()
                                    Text(problem.stage.rawValue)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.semibold))
                                if let path = problem.relativePath {
                                    Text(location(path: path, line: problem.line, column: problem.column))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(problem.message)
                                    .font(.callout)
                                if let recovery = problem.recoveryAction {
                                    Text(recovery)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(10)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace problems panel")
    }

    private func location(path: String, line: Int?, column: Int?) -> String {
        var result = path
        if let line { result += ":\(line)" }
        if let column { result += ":\(column)" }
        return result
    }
}
