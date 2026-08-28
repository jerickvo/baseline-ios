import SwiftUI

@main
struct BaselineLoggerApp: App {
    /// One recorder for the whole app lifetime. It must not be recreated
    /// mid-session, so it lives at the root, not inside a view.
    @StateObject private var recorder = SessionRecorder()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(recorder)
        }
    }
}
