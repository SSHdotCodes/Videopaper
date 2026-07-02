import SwiftUI

struct DisplayDetailView: View {
    @ObservedObject var store: WallpaperStore
    let display: DisplayInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.name)
                            .font(.largeTitle.weight(.semibold))

                        Text(display.isMain ? "Main display" : "Secondary display")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("Enabled", isOn: Binding(
                        get: { store.isDisplayEnabled(display) },
                        set: { store.setDisplay(display, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                }

                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailRow(title: "Pixel Resolution", value: display.resolutionLabel)
                        DetailRow(title: "Window Frame", value: display.frameLabel)
                        DetailRow(title: "Display ID", value: display.id)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Wallpaper") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Use custom wallpaper on this display", isOn: Binding(
                            get: { store.usesCustomProfile(display) },
                            set: { store.setUsesCustomProfile(display, enabled: $0) }
                        ))
                        .toggleStyle(.switch)

                        Divider()

                        if store.usesCustomProfile(display) {
                            ProfileSourceEditor(store: store, display: display)
                            ProfilePlaybackEditor(store: store, display: display)
                        } else {
                            let profile = store.settings.defaultProfile
                            DetailRow(title: "Following", value: "All Displays")
                            DetailRow(title: "Source", value: profile.sourceMode.title)

                            if profile.sourceMode == .ambient {
                                DetailRow(title: "Template", value: profile.ambientStyle.title)
                            } else {
                                DetailRow(title: "Video", value: profile.summary)
                            }

                            DetailRow(title: "Dimming", value: "\(Int(profile.dimming * 100))%")
                        }

                        HStack {
                            Button {
                                store.apply()
                            } label: {
                                Label(store.isRunning ? "Refresh" : "Apply", systemImage: store.isRunning ? "arrow.clockwise" : "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                store.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .disabled(!store.isRunning)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct ProfileSourceEditor: View {
    @ObservedObject var store: WallpaperStore
    let display: DisplayInfo

    var body: some View {
        let profile = store.profile(for: display)

        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: store.displayProfileBinding(display, \.sourceMode)) {
                ForEach(WallpaperSourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if profile.sourceMode == .video {
                DisplayVideoControls(store: store, display: display)
            } else {
                AmbientTemplatePicker(selectedStyle: profile.ambientStyle) { style in
                    store.setDisplayProfileValue(style, for: display, \.ambientStyle)
                }
            }
        }
    }
}

private struct DisplayVideoControls: View {
    @ObservedObject var store: WallpaperStore
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    store.chooseVideo(for: display)
                } label: {
                    Label(store.selectedVideoURL(for: display) == nil ? "Choose Video..." : "Change Video...", systemImage: "film")
                }

                if store.selectedVideoURL(for: display) != nil {
                    Button {
                        store.revealVideoInFinder(for: display)
                    } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                    }
                }
            }

            if let url = store.selectedVideoURL(for: display) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Choose a video file for this display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProfilePlaybackEditor: View {
    @ObservedObject var store: WallpaperStore
    let display: DisplayInfo

    var body: some View {
        let profile = store.profile(for: display)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Picker("Fit", selection: store.displayProfileBinding(display, \.fitMode)) {
                    ForEach(VideoFitMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .frame(width: 220)

                Picker("Render Limit", selection: store.displayProfileBinding(display, \.renderLimit)) {
                    ForEach(RenderLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .frame(width: 220)
            }
            .disabled(profile.sourceMode != .video)

            Toggle("Loop video", isOn: store.displayProfileBinding(display, \.loopVideo))
                .toggleStyle(.checkbox)
                .disabled(profile.sourceMode != .video)

            HStack {
                Text("Speed")
                    .frame(width: 86, alignment: .leading)
                Slider(value: store.displayProfileBinding(display, \.playbackRate), in: 0.25...2.0, step: 0.05)
                Text(String(format: "%.2fx", profile.playbackRate))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .disabled(profile.sourceMode != .video)

            Toggle("Mute audio", isOn: store.displayProfileBinding(display, \.muted))
                .toggleStyle(.checkbox)
                .disabled(profile.sourceMode != .video)

            HStack {
                Text("Volume")
                    .frame(width: 86, alignment: .leading)
                Slider(value: store.displayProfileBinding(display, \.volume), in: 0...1, step: 0.05)
                Text("\(Int(profile.volume * 100))%")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .disabled(profile.sourceMode != .video || profile.muted)

            HStack {
                Text("Dimming")
                    .frame(width: 86, alignment: .leading)
                Slider(value: store.displayProfileBinding(display, \.dimming), in: 0...0.8, step: 0.02)
                Text("\(Int(profile.dimming * 100))%")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.top, 4)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            Text(value)
                .textSelection(.enabled)

            Spacer()
        }
    }
}
