import LiteTermCore
import SwiftUI

struct HostListScreen: View {
    @ObservedObject var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var editedHost: SSHHost?
    @State private var isCreatingHost = false
    @State private var pendingDeletion: SSHHost?

    var body: some View {
        NavigationStack {
            Group {
                if store.hosts.isEmpty {
                    ContentUnavailableView(
                        "No SSH Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host to prepare a password or LiteTerm-generated key connection.")
                    )
                } else {
                    List {
                        if !store.loadIssues.isEmpty {
                            Section {
                                Label(
                                    "\(store.loadIssues.count) malformed record(s) were ignored.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                        Section("Saved hosts") {
                            ForEach(store.hosts) { host in
                                Button {
                                    editedHost = host
                                } label: {
                                    HostRow(host: host)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        pendingDeletion = host
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("SSH Hosts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingHost = true
                    } label: {
                        Label("Add host", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorScreen(store: store, host: nil)
        }
        .sheet(item: $editedHost) { host in
            HostEditorScreen(store: store, host: host)
        }
        .confirmationDialog(
            "Delete this host and its saved credentials?",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete host", role: .destructive) {
                if let pendingDeletion {
                    store.delete(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        }
        .alert("Host storage", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "Host storage failed.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }
}

private struct HostRow: View {
    let host: SSHHost

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.label)
                .font(.headline)
            Text("\(host.username)@\(host.hostname):\(host.port)")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
            Text(host.authenticationKind == .password ? "Password" : "LiteTerm Ed25519 key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
