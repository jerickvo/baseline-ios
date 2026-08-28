import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                RecordView()
            }
            .tabItem { Label("Record", systemImage: "record.circle") }

            NavigationStack {
                SessionListView()
            }
            .tabItem { Label("Sessions", systemImage: "list.bullet") }
        }
    }
}
