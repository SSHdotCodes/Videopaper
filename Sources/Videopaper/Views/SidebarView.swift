import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        List(selection: $store.selection) {
            Section("Wallpaper") {
                Label("Setup", systemImage: "slider.horizontal.3")
                    .tag(DisplaySelection.all)
            }

            Section("Displays") {
                ForEach(store.displays) { display in
                    DisplaySidebarRow(
                        display: display,
                        isEnabled: store.isDisplayEnabled(display),
                        isCustom: store.usesCustomProfile(display),
                        summary: store.profile(for: display).summary
                    )
                    .tag(DisplaySelection.display(display.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DisplaySidebarRow: View {
    let display: DisplayInfo
    let isEnabled: Bool
    let isCustom: Bool
    let summary: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isMain ? "display" : "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .lineLimit(1)

                Text(isCustom ? "Custom: \(summary)" : "\(display.resolutionLabel) - Default")
                    .font(.caption)
                    .foregroundStyle(isCustom ? .primary : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
    }
}
