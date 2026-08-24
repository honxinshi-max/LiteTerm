import SwiftUI

struct TerminalScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Text("Local commands can access only App Documents or a folder you choose in Files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("Files access scope")
                TerminalViewRepresentable(session: model.terminalSession)
                    .background(Color(red: 0.035, green: 0.043, blue: 0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ShortcutBar(session: model.terminalSession)
            }
            .background(Color(red: 0.055, green: 0.066, blue: 0.082).ignoresSafeArea())
            .navigationTitle("LiteTerm")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isShowingFolderPicker) {
            FolderPicker(
                onSelection: model.completeFolderSelection,
                onCancel: { model.isShowingFolderPicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $model.isShowingHosts) {
            HostListScreen(
                store: model.hostStore,
                sshSession: model.sshSession,
                onConnect: model.connect(to:)
            )
        }
        .sheet(item: $model.editorDocument) { document in
            TextFileEditor(url: document.url) { _ in
                model.editorDocument = nil
            }
        }
        .alert("Folder access", isPresented: folderErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authorizationErrorMessage ?? "Folder authorization failed.")
        }
        .alert(item: $model.deletionConfirmationRequest) { request in
            Alert(
                title: Text("Delete this file?"),
                message: Text(request.targetURL.path),
                primaryButton: .destructive(Text("Delete")) {
                    model.confirmDeletion(request)
                },
                secondaryButton: .cancel {
                    model.cancelDeletion(request)
                }
            )
        }
        .background(SSHHostTrustPresenter(session: model.sshSession))
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                modePicker
                Spacer(minLength: 8)
                ConnectionBadge(mode: model.mode, session: model.terminalSession)
                folderMenu
                if model.canRequestHosts {
                    hostsButton
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    modePicker
                    Spacer()
                    ConnectionBadge(mode: model.mode, session: model.terminalSession)
                }
                HStack {
                    folderMenu
                    if model.canRequestHosts {
                        hostsButton
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var modePicker: some View {
        Picker("Terminal mode", selection: $model.mode) {
            ForEach(TerminalMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
        .accessibilityIdentifier("Terminal mode")
    }

    private var folderMenu: some View {
        Menu {
            Button("App Documents", action: model.useAppDocuments)
            Button("Choose Folder…", action: model.chooseExternalFolder)
        } label: {
            Label(model.activeWorkspaceName, systemImage: "folder")
                .lineLimit(1)
        }
        .accessibilityLabel("Workspace folder")
    }

    private var hostsButton: some View {
        Button(action: model.requestHosts) {
            Label("Hosts", systemImage: "server.rack")
        }
        .accessibilityIdentifier("Host actions")
    }

    private var folderErrorBinding: Binding<Bool> {
        Binding(
            get: { model.authorizationErrorMessage != nil },
            set: { if !$0 { model.authorizationErrorMessage = nil } }
        )
    }
}

private struct SSHHostTrustPresenter: View {
    @ObservedObject var session: SSHSessionController

    var body: some View {
        Color.clear
            .sheet(item: $session.pendingHostTrust) { request in
                HostKeyTrustSheet(
                    hostLabel: request.hostLabel,
                    presentedFingerprint: request.fingerprint,
                    kind: request.kind,
                    onTrust: session.confirmHostTrust,
                    onCancel: session.cancelHostTrust
                )
                .interactiveDismissDisabled()
            }
    }
}

private struct ConnectionBadge: View {
    let mode: TerminalMode
    @ObservedObject var session: TerminalSessionCoordinator

    var body: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(mode == .local ? Color.mint : Color.secondary)
            .accessibilityIdentifier(statusText)
    }

    private var statusText: String {
        mode == .local ? "Local workspace" : session.remoteStatus.rawValue
    }

    private var statusIcon: String {
        mode == .local ? "internaldrive" : "network"
    }
}
