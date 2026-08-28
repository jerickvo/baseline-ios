import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            SessionListView()
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
        }
    }
}
