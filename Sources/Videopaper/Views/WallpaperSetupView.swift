import SwiftUI

struct WallpaperSetupView: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(store: store)
                SourceSection(store: store)
                DisplaySection(store: store)
                PlaybackSection(store: store)
                LaunchSection(store: store)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Videopaper")
                        .font(.largeTitle.weight(.semibold))

                    Text("Animated and video wallpapers for every display.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        store.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!store.isRunning)

                    Button {
                        store.apply()
                    } label: {
                        Label(store.isRunning ? "Refresh" : "Apply", systemImage: store.isRunning ? "arrow.clockwise" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Label(store.statusMessage, systemImage: store.isRunning ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(store.isRunning ? .green : .secondary)
                .lineLimit(2)
        }
    }
}

private struct SourceSection: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Source", selection: setting(\.sourceMode)) {
                    ForEach(WallpaperSourceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if store.settings.sourceMode == .video {
                    VideoFileControls(store: store)
                } else {
                    AmbientTemplatePicker(selectedStyle: store.settings.ambientStyle) { style in
                        store.set(style, for: \.ambientStyle)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<WallpaperSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.set($0, for: keyPath) }
        )
    }
}

struct AmbientTemplatePicker: View {
    let selectedStyle: AmbientStyle
    let onSelect: (AmbientStyle) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 152, maximum: 196), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(AmbientStyle.allCases) { style in
                AmbientTemplateTile(
                    style: style,
                    isSelected: selectedStyle == style
                ) {
                    onSelect(style)
                }
            }
        }
    }
}

struct AmbientTemplateTile: View {
    let style: AmbientStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: style.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : .accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(.headline)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(style.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VideoFileControls: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    store.chooseVideo()
                } label: {
                    Label(store.selectedVideoURL == nil ? "Choose Video..." : "Change Video...", systemImage: "film")
                }

                if store.selectedVideoURL != nil {
                    Button {
                        store.revealVideoInFinder()
                    } label: {
                        Label("Reveal", systemImage: "magnifyingglass")
                    }
                }
            }

            if let url = store.selectedVideoURL, let metadata = store.videoMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadata.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(metadata.resolutionLabel)  |  \(metadata.durationLabel)  |  \(metadata.fileSizeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("MP4, MOV, M4V, MKV, and WebM files are accepted when macOS can decode them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DisplaySection: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        GroupBox("Displays") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(store.displays.count) detected")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Enable All") {
                        store.enableAllDisplays()
                    }

                    Button("Disable All") {
                        store.disableAllDisplays()
                    }
                }

                Divider()

                ForEach(store.displays) { display in
                    Toggle(isOn: Binding(
                        get: { store.isDisplayEnabled(display) },
                        set: { store.setDisplay(display, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.name)
                                .font(.body)

                            Text("\(display.resolutionLabel) pixels  |  \(display.frameLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(store.usesCustomProfile(display) ? "Custom: \(store.profile(for: display).summary)" : "Default: \(store.settings.defaultProfile.summary)")
                                .font(.caption)
                                .foregroundStyle(store.usesCustomProfile(display) ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PlaybackSection: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        GroupBox("Playback") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Picker("Fit", selection: setting(\.fitMode)) {
                        ForEach(VideoFitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(width: 220)

                    Picker("Render Limit", selection: setting(\.renderLimit)) {
                        ForEach(RenderLimit.allCases) { limit in
                            Text(limit.title).tag(limit)
                        }
                    }
                    .frame(width: 220)
                }
                .disabled(store.settings.sourceMode != .video)

                Toggle("Loop video", isOn: setting(\.loopVideo))
                    .toggleStyle(.checkbox)
                    .disabled(store.settings.sourceMode != .video)

                HStack {
                    Text("Speed")
                        .frame(width: 86, alignment: .leading)
                    Slider(value: setting(\.playbackRate), in: 0.25...2.0, step: 0.05)
                    Text(String(format: "%.2fx", store.settings.playbackRate))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .disabled(store.settings.sourceMode != .video)

                Toggle("Mute audio", isOn: setting(\.muted))
                    .toggleStyle(.checkbox)
                    .disabled(store.settings.sourceMode != .video)

                HStack {
                    Text("Volume")
                        .frame(width: 86, alignment: .leading)
                    Slider(value: setting(\.volume), in: 0...1, step: 0.05)
                    Text("\(Int(store.settings.volume * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .disabled(store.settings.sourceMode != .video || store.settings.muted)

                HStack {
                    Text("Dimming")
                        .frame(width: 86, alignment: .leading)
                    Slider(value: setting(\.dimming), in: 0...0.8, step: 0.02)
                    Text("\(Int(store.settings.dimming * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<WallpaperSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.set($0, for: keyPath) }
        )
    }
}

private struct LaunchSection: View {
    @ObservedObject var store: WallpaperStore

    var body: some View {
        GroupBox("Launch") {
            Toggle("Apply saved wallpaper when Videopaper opens", isOn: Binding(
                get: { store.settings.applyOnLaunch },
                set: { store.set($0, for: \.applyOnLaunch) }
            ))
            .toggleStyle(.checkbox)
            .padding(.vertical, 4)
        }
    }
}
