import LiteSpaceCore
import SwiftUI

struct CodeEditorScreen: View {
    let rootURL: URL
    let relativePath: String?
    let onSaved: () -> Void
    @Binding var hasUnsavedChanges: Bool

    @State private var text = ""
    @State private var savedText = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(relativePath ?? "Editor", systemImage: "doc.text")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isLoaded || isLoading || isSaving)
                    .accessibilityIdentifier("Workspace save")
            }
            .padding(10)
            .background(.thinMaterial)

            Group {
                if relativePath == nil {
                    ContentUnavailableView(
                        "Choose a source file",
                        systemImage: "doc.text",
                        description: Text("Select a file from the workspace browser.")
                    )
                } else if isLoading {
                    ProgressView("Opening source…")
                } else if isLoaded {
                    TextEditor(text: $text)
                        .font(.system(size: 15, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .accessibilityIdentifier("Workspace code editor")
                } else {
                    ContentUnavailableView(
                        "Source unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("Only root-contained UTF-8 files up to 5 MiB can be edited.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.045, green: 0.052, blue: 0.066))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace editor column")
        .task(id: relativePath) { await load() }
        .onChange(of: text) { _, newValue in
            if isLoaded {
                hasUnsavedChanges = newValue != savedText
            }
        }
        .alert("Unable to edit source", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The file operation failed.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func sourceURL() -> URL? {
        guard let relativePath,
              WorkspaceRelativePathPolicy.isValidFilePath(relativePath) else { return nil }
        return relativePath.split(separator: "/").reduce(rootURL) {
            $0.appendingPathComponent(String($1))
        }
    }

    @MainActor
    private func load() async {
        text = ""
        savedText = ""
        hasUnsavedChanges = false
        isLoaded = false
        guard let sourceURL = sourceURL() else {
            isLoading = false
            return
        }
        isLoading = true
        do {
            let loadedText = try await Task.detached {
                try CoordinatedFileAccess.readText(from: sourceURL, inside: rootURL)
            }.value
            text = loadedText
            savedText = loadedText
            isLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        guard let sourceURL = sourceURL() else { return }
        isSaving = true
        let draft = text
        Task { @MainActor in
            do {
                try await Task.detached {
                    try CoordinatedFileAccess.writeText(draft, to: sourceURL, inside: rootURL)
                }.value
                savedText = draft
                hasUnsavedChanges = false
                isSaving = false
                onSaved()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
