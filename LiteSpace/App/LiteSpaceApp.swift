import SwiftUI

@main
struct LiteSpaceApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LiteSpaceRootScreen(model: model)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    switch newPhase {
                    case .active:
                        model.didBecomeActive()
                    case .background:
                        model.didEnterBackground()
                    case .inactive:
                        model.didBecomeInactive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
