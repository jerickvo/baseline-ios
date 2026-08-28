import SwiftUI

@main
struct BaselineLoggerApp: App {
    @StateObject private var engine = RecordingEngine()
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(store)
        }
    }
}
