import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var playerVM = PlayerViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        PlaylistListView()
            .environmentObject(playerVM)
            .onAppear {
                playerVM.configure(modelContext: modelContext)
            }
    }
}
