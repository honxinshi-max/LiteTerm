import SwiftUI

private enum LiteTermSurface: Hashable {
    case terminal
    case workspace
}

struct LiteTermRootScreen: View {
    @ObservedObject var model: AppModel
    @State private var selection: LiteTermSurface = .terminal
    @State private var pendingSelection: LiteTermSurface?

    private var guardedSelection: Binding<LiteTermSurface> {
        Binding(
            get: { selection },
            set: { requested in
                guard requested != selection else { return }
                if selection == .workspace && model.workspaceHasUnsavedChanges {
                    pendingSelection = requested
                } else {
                    selection = requested
                }
            }
        )
    }

    var body: some View {
        TabView(selection: guardedSelection) {
            Group {
                if selection == .terminal {
                    TerminalScreen(model: model)
                } else {
                    Color.clear
                }
            }
            .tabItem { Label("Terminal", systemImage: "terminal") }
            .tag(LiteTermSurface.terminal)

            Group {
                if selection == .workspace {
                    WorkspaceScreen(model: model)
                } else {
                    Color.clear
                }
            }
            .tabItem { Label("Local Workspace", systemImage: "chevron.left.forwardslash.chevron.right") }
            .tag(LiteTermSurface.workspace)
        }
        .onChange(of: selection, initial: true) { _, surface in
            if surface == .workspace {
                model.mode = .local
            }
        }
        .alert("Discard unsaved workspace changes?", isPresented: discardAlertBinding) {
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
            Button("Discard Changes", role: .destructive) {
                model.workspaceHasUnsavedChanges = false
                if let pendingSelection {
                    selection = pendingSelection
                }
                self.pendingSelection = nil
            }
        } message: {
            Text("Save the current file before leaving Local Workspace, or discard the in-memory draft.")
        }
        .preferredColorScheme(.dark)
    }

    private var discardAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingSelection != nil },
            set: { if !$0 { pendingSelection = nil } }
        )
    }
}
