import SwiftUI

struct TextFileEditor: View {
    let url: URL
    let onSave: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isLoading = true
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Opening file…")
                } else if isLoaded {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(8)
                        .accessibilityIdentifier("Native text editor")
                } else {
                    ContentUnavailableView(
                        "File unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("Cancel and choose an editable UTF-8 file no larger than 5 MiB.")
                    )
                }
            }
            .navigationTitle("Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isLoading || !isLoaded || isSaving)
                }
            }
        }
        .task(id: url) {
            await load()
        }
        .alert("Unable to edit file", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The operation failed.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func load() async {
        isLoading = true
        isLoaded = false
        do {
            text = try await Task.detached {
                try CoordinatedFileAccess.readText(from: url)
            }.value
            isLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        isSaving = true
        let draft = text
        Task { @MainActor in
            do {
                try await Task.detached {
                    try CoordinatedFileAccess.writeText(draft, to: url)
                }.value
                onSave(url)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
