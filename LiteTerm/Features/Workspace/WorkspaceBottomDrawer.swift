import SwiftUI

private enum WorkspaceBottomPanel: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case problems = "Problems"
    case ports = "Ports"

    var id: Self { self }
}

struct WorkspaceBottomDrawer: View {
    @ObservedObject var terminalSession: TerminalSessionCoordinator
    @ObservedObject var controller: WorkspaceController

    @State private var panel: WorkspaceBottomPanel = .terminal

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Workspace bottom panel", selection: $panel) {
                    ForEach(WorkspaceBottomPanel.allCases) { panel in
                        Text(panel.rawValue).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("Workspace bottom panel")
                Spacer(minLength: 8)
                if !controller.presentation.problems.isEmpty {
                    Text("\(controller.presentation.problems.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.2), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial)

            switch panel {
            case .terminal:
                VStack(spacing: 0) {
                    TerminalViewRepresentable(session: terminalSession)
                        .background(Color(red: 0.035, green: 0.043, blue: 0.055))
                    ShortcutBar(session: terminalSession)
                }
            case .problems:
                WorkspaceProblemsPanel(problems: controller.presentation.problems)
            case .ports:
                WorkspacePortsPanel(port: controller.presentation.publishedPort)
            }
        }
        .background(Color(red: 0.035, green: 0.043, blue: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace bottom drawer")
    }
}
