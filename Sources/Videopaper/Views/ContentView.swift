import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            DetailView(store: store)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.chooseVideo()
                } label: {
                    Label("Choose Video", systemImage: "film")
                }

                Button {
                    store.apply()
                } label: {
                    Label(store.isRunning ? "Refresh" : "Apply", systemImage: store.isRunning ? "arrow.clockwise" : "play.fill")
                }

                Button {
                    store.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!store.isRunning)
            }
        }
    }
}
