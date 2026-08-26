import SwiftUI

@main
struct LiteTermApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LiteTermRootScreen(model: model)
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
