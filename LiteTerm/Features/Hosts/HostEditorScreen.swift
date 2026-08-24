import LiteTermCore
import SwiftUI

struct HostEditorScreen: View {
    @ObservedObject var store: HostStore
    @Environment(\.dismiss) private var dismiss

    private let hostID: UUID
    private let isNewHost: Bool
    @State private var label: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authenticationKind: SSHAuthenticationKind
    @State private var reconnectIsEnabled: Bool
    @State private var password = ""
    @State private var validationMessage: String?

    init(store: HostStore, host: SSHHost?) {
        self.store = store
        hostID = host?.id ?? UUID()
        isNewHost = host == nil
        _label = State(initialValue: host?.label ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _authenticationKind = State(initialValue: host?.authenticationKind ?? .password)
        _reconnectIsEnabled = State(initialValue: host?.reconnectPreference != .disabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Label", text: $label)
#if os(iOS)
                    TextField("Hostname", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#else
                    TextField("Hostname", text: $hostname)
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
#endif
                }

                Section("Authentication") {
                    Picker("Method", selection: $authenticationKind) {
                        Text("Password").tag(SSHAuthenticationKind.password)
                        Text("Generated Ed25519 key").tag(SSHAuthenticationKind.generatedKey)
                    }
                    if authenticationKind == .password {
#if os(iOS)
                        SecureField(isNewHost ? "Password" : "New password (leave blank to keep)", text: $password)
                            .textContentType(.password)
#else
                        SecureField(isNewHost ? "Password" : "New password (leave blank to keep)", text: $password)
#endif
                    } else {
                        Text("LiteTerm will generate and protect an Ed25519 key. Importing arbitrary private keys is not supported.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Connection") {
                    Toggle("Reconnect after transport loss", isOn: $reconnectIsEnabled)
                    Text("Reconnect is limited to three foreground attempts after transport loss.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isNewHost ? "Add Host" : "Edit Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
        .alert("Host details", isPresented: validationBinding) {
            Button("OK", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "Host details are invalid.")
        }
    }

    private func save() {
        do {
            guard let parsedPort = Int(port) else {
                throw SSHHostValidationError.invalidPort(0)
            }
            let host = try SSHHost(
                id: hostID,
                label: label,
                hostname: hostname,
                port: parsedPort,
                username: username,
                authenticationKind: authenticationKind,
                reconnectPreference: reconnectIsEnabled ? .enabled : .disabled
            )
            try store.upsert(host, password: password.isEmpty ? nil : password)
            dismiss()
        } catch {
            validationMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        guard let validationError = error as? SSHHostValidationError else {
            return error.localizedDescription
        }
        switch validationError {
        case .emptyLabel:
            return "Enter a host label."
        case .emptyHostname:
            return "Enter a hostname or IP address."
        case .invalidPort:
            return "Enter a port from 1 through 65535."
        case .emptyUsername:
            return "Enter a username."
        }
    }

    private var validationBinding: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }
}
