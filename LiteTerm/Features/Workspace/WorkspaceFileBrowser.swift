import LiteTermCore
import SwiftUI

@MainActor
private final class WorkspaceFileBrowserModel: ObservableObject {
    @Published private(set) var relativePaths: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let inventory = WorkspaceInventoryService()
    private var loadTask: Task<Void, Never>?

    func load(rootURL: URL, refreshID: UInt64) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inspection = try await inventory.inspect(rootURL: rootURL)
                try Task.checkCancellation()
                relativePaths = inspection.evaluation.acceptedFiles.map(\.relativePath)
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                relativePaths = []
                errorMessage = "The selected folder could not be inspected."
                isLoading = false
            }
        }
    }
}

struct WorkspaceFileBrowser: View {
    let rootURL: URL
    @Binding var selectedPath: String?
    let refreshID: UInt64

    @StateObject private var browser = WorkspaceFileBrowserModel()

    var body: some View {
        Group {
            if browser.isLoading && browser.relativePaths.isEmpty {
                ProgressView("Inspecting files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = browser.errorMessage {
                ContentUnavailableView(
                    "Files unavailable",
                    systemImage: "folder.badge.questionmark",
                    description: Text(errorMessage)
                )
            } else if browser.relativePaths.isEmpty {
                ContentUnavailableView(
                    "No editable source",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a bounded Web, Python, or Swift folder.")
                )
            } else {
                List(browser.relativePaths, id: \.self, selection: $selectedPath) { path in
                    Button {
                        selectedPath = path
                    } label: {
                        Label(path, systemImage: icon(for: path))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedPath == path ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                }
                .listStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace file browser")
        .task(id: "\(rootURL.standardizedFileURL.path)|\(refreshID)") {
            browser.load(rootURL: rootURL, refreshID: refreshID)
        }
    }

    private func icon(for path: String) -> String {
        switch path.split(separator: ".").last?.lowercased() {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "js", "mjs": return "curlybraces"
        case "py": return "p.square"
        case "swift": return "swift"
        default: return "doc.text"
        }
    }
}
