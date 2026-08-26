import LiteSpaceCore
import SwiftUI

struct HostListScreen: View {
    @ObservedObject var store: HostStore
    @ObservedObject var sshSession: SSHSessionController
    let onConnect: (SSHHost) -> Void
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
                        description: Text("Add a host to prepare a password or LiteSpace-generated key connection.")
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
                                HStack(spacing: 12) {
                                    HostRow(
                                        host: host,
                                        credentialState: store.credentialStates[host.id]
                                    )
                                    Spacer(minLength: 8)
                                    hostActions(for: host)
                                }
                                .swipeActions {
                                    Button("Edit") {
                                        editedHost = host
                                    }
                                    .tint(.blue)
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
        .sheet(item: $store.generatedPublicKey) { presentation in
            GeneratedPublicKeySheet(presentation: presentation) {
                store.dismissGeneratedPublicKey()
            }
        }
        .confirmationDialog(
            "Delete this host and its saved credentials?",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete host", role: .destructive) {
                if let pendingDeletion {
                    if sshSession.activeHostID == pendingDeletion.id {
                        sshSession.disconnect()
                    }
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

    @ViewBuilder
    private func hostActions(for host: SSHHost) -> some View {
        let credentialState = store.credentialStates[host.id]
        if host.authenticationKind == .generatedKey, credentialState == .setupRequired {
            Button("Generate Key") {
                store.generateKey(for: host)
            }
            .buttonStyle(.bordered)
        } else if isActiveConnection(for: host) {
            Button("Disconnect", role: .destructive) {
                sshSession.disconnect()
            }
            .buttonStyle(.bordered)
        } else {
            Button("Connect") {
                onConnect(host)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(credentialState != .ready)
        }

        if host.authenticationKind == .generatedKey, credentialState == .ready {
            Button {
                store.showGeneratedPublicKey(for: host)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Show generated public key")
        }
    }

    private func isActiveConnection(for host: SSHHost) -> Bool {
        guard sshSession.activeHostID == host.id else { return false }
        switch sshSession.state {
        case .disconnected, .failed:
            return false
        default:
            return true
        }
    }
}

private struct GeneratedPublicKeySheet: View {
    let presentation: GeneratedPublicKeyPresentation
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Install this public key in the remote account's authorized_keys file.")
                    .foregroundStyle(.secondary)
                Text(presentation.publicKey)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text("LiteSpace never displays or exports the private key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle(presentation.hostLabel)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

private struct HostRow: View {
    let host: SSHHost
    let credentialState: HostCredentialState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.label)
                .font(.headline)
            Text("\(host.username)@\(host.hostname):\(host.port)")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
            Text(host.authenticationKind == .password ? "Password" : "LiteSpace Ed25519 key")
                .font(.caption)
                .foregroundStyle(.secondary)
            if credentialState == .setupRequired {
                Label("Credential setup required", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if credentialState == .repairRequired {
                Label("Credential repair required", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
