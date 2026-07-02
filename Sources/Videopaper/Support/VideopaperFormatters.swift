import AVFoundation
import Foundation

enum VideopaperFormatters {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "Unknown duration"
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    static func fileSize(_ byteCount: Int64?) -> String {
        guard let byteCount else {
            return "Unknown size"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    static func metadata(for url: URL) async -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let durationSeconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let track = (try? await asset.loadTracks(withMediaType: .video))?.first
        let naturalSize = (try? await track?.load(.naturalSize)) ?? .zero
        let transform = (try? await track?.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(transform)
        let width = abs(Int(transformedSize.width.rounded()))
        let height = abs(Int(transformedSize.height.rounded()))
        let resolution = width > 0 && height > 0 ? "\(width) x \(height)" : "Unknown resolution"
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])

        return VideoMetadata(
            fileName: url.lastPathComponent,
            durationLabel: duration(durationSeconds),
            resolutionLabel: resolution,
            fileSizeLabel: fileSize(values?.fileSize.map(Int64.init))
        )
    }
}
