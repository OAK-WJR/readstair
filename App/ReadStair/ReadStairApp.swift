import SwiftUI

@main
struct ReadStairApp: App {
    /// Creating the model does nothing; `launch()` opens the store.
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG && READSTAIR_ICLOUD
            if DebugLaunch.syncSelfTest {
                SyncSelfTestView()
            } else {
                root
            }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }

    private var root: some View {
        RootView()
            .environment(app)
            .task { await app.launch() }
    }
}
