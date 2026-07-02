import SwiftUI

struct DetailView: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        Group {
            if let display = store.selectedDisplay {
                DisplayDetailView(store: store, display: display)
            } else {
                WallpaperSetupView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
