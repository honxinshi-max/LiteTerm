import SwiftUI

private enum LiteTermSurface: Hashable {
    case terminal
    case workspace
}

struct LiteTermRootScreen: View {
    @ObservedObject var model: AppModel
    @State private var selection: LiteTermSurface = .terminal

    var body: some View {
        TabView(selection: $selection) {
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
            .tabItem { Label("Workspace", systemImage: "chevron.left.forwardslash.chevron.right") }
            .tag(LiteTermSurface.workspace)
        }
        .onChange(of: selection, initial: true) { _, surface in
            if surface == .workspace {
                model.mode = .local
            }
        }
        .preferredColorScheme(.dark)
    }
}
