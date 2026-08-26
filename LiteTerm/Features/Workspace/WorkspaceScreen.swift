import LiteTermCore
import SwiftUI

struct WorkspaceScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: WorkspaceController

    @State private var selectedPath: String?
    @State private var isShowingBrowser = true
    @State private var isShowingBrowserSheet = false
    @State private var isShowingPreview = true
    @State private var browserRefreshID: UInt64 = 0

    init(model: AppModel) {
        self.model = model
        controller = model.workspaceController
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            VStack(spacing: 8) {
                controls(landscape: landscape)
                workspaceContent(landscape: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WorkspaceBottomDrawer(
                    terminalSession: model.terminalSession,
                    controller: controller
                )
                .frame(height: min(280, max(210, proxy.size.height * 0.31)))
            }
            .padding(10)
            .background(Color(red: 0.055, green: 0.066, blue: 0.082).ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Workspace screen")
            .sheet(isPresented: $isShowingBrowserSheet) {
                NavigationStack {
                    WorkspaceFileBrowser(
                        rootURL: model.activeWorkspaceURL,
                        selectedPath: $selectedPath,
                        refreshID: browserRefreshID
                    )
                    .navigationTitle("Workspace Files")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingBrowserSheet = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $model.isShowingFolderPicker) {
            FolderPicker(
                onSelection: model.completeFolderSelection,
                onCancel: { model.isShowingFolderPicker = false }
            )
            .ignoresSafeArea()
        }
        .alert("Folder access", isPresented: folderErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authorizationErrorMessage ?? "Folder authorization failed.")
        }
        .onAppear { model.mode = .local }
        .onChange(of: model.activeWorkspaceName) { _, _ in
            selectedPath = nil
            browserRefreshID &+= 1
            isShowingPreview = true
        }
    }

    @ViewBuilder
    private func workspaceContent(landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: 8) {
                if isShowingBrowser {
                    WorkspaceFileBrowser(
                        rootURL: model.activeWorkspaceURL,
                        selectedPath: $selectedPath,
                        refreshID: browserRefreshID
                    )
                    .frame(width: 260)
                    .background(panelBackground, in: RoundedRectangle(cornerRadius: 10))
                }
                CodeEditorScreen(
                    rootURL: model.activeWorkspaceURL,
                    relativePath: selectedPath,
                    onSaved: sourceSaved
                )
                .frame(minWidth: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if isShowingPreview, controller.presentation.previewAvailable {
                    WorkspacePreview(controller: controller)
                        .frame(minWidth: 280, idealWidth: 390)
                }
            }
        } else {
            VStack(spacing: 8) {
                CodeEditorScreen(
                    rootURL: model.activeWorkspaceURL,
                    relativePath: selectedPath,
                    onSaved: sourceSaved
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if isShowingPreview, controller.presentation.previewAvailable {
                    WorkspacePreview(controller: controller)
                        .frame(minHeight: 180)
                }
            }
        }
    }

    private func controls(landscape: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("App Documents", action: model.useAppDocuments)
                    Button("Choose Folder…", action: model.chooseExternalFolder)
                } label: {
                    Label(model.activeWorkspaceName, systemImage: "folder")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                if landscape {
                    Button {
                        isShowingBrowser.toggle()
                    } label: {
                        Label("Files", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Workspace files")
                } else {
                    Button {
                        isShowingBrowserSheet = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Workspace files")
                }

                Divider().frame(height: 26)
                actionButton("Check", systemImage: "checkmark.circle", id: "Workspace check") {
                    controller.perform(.check)
                }
                actionButton("Test", systemImage: "testtube.2", id: "Workspace test") {
                    controller.perform(.test)
                }
                actionButton("Run", systemImage: "play.fill", id: "Workspace run", prominent: true) {
                    controller.perform(.run)
                }
                actionButton("Stop", systemImage: "stop.fill", id: "Workspace stop") {
                    Task { await controller.stopAndInvalidate() }
                }

                Button {
                    isShowingPreview.toggle()
                } label: {
                    Label("Preview", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .disabled(!controller.presentation.previewAvailable)

                if controller.presentation.playgroundsHandoff != nil {
                    ShareLink(item: model.activeWorkspaceURL) {
                        Label("Open in Swift Playgrounds", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("Swift Playgrounds handoff")
                }

                Label(controller.presentation.statusText, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.13), in: Capsule())
                    .accessibilityIdentifier("Workspace gate state")
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        id: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(id)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
        }
    }

    private var panelBackground: Color {
        Color(red: 0.045, green: 0.052, blue: 0.066)
    }

    private var statusIcon: String {
        switch controller.presentation.state {
        case .ready, .checked, .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .idle: return "circle"
        default: return "hourglass"
        }
    }

    private var statusColor: Color {
        switch controller.presentation.state {
        case .ready, .checked, .completed: return .mint
        case .failed: return .red
        case .idle: return .secondary
        default: return .yellow
        }
    }

    private var folderErrorBinding: Binding<Bool> {
        Binding(
            get: { model.authorizationErrorMessage != nil },
            set: { if !$0 { model.authorizationErrorMessage = nil } }
        )
    }

    private func sourceSaved() {
        browserRefreshID &+= 1
        model.workspaceSourceDidChange()
    }
}
