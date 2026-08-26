import SwiftUI

struct WorkspacePortsPanel: View {
    let port: Int?

    var body: some View {
        Group {
            if let port {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Verified local service")
                            .font(.headline)
                        Text("127.0.0.1:\(port)")
                            .font(.system(.body, design: .monospaced))
                        Text("Available only inside LiteSpace on this iPad.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            } else {
                ContentUnavailableView(
                    "No verified service port",
                    systemImage: "network.slash",
                    description: Text("A port appears only after every gate and three health checks pass.")
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Workspace ports panel")
    }
}
