import AVFoundation
import Photos
import UIKit

/// Finishes a take: makes the combined video if wanted, joins lens-switch pieces, saves to
/// Photos and cleans up. Runs only while nothing is recording; a new recording cancels it and
/// the take is finished afterwards.
enum TakeSaver {
    struct Outcome {
        var thumbnail: UIImage?
        /// Something the person should know, shown in the yellow pill.
        var message: String?
        /// Interrupted by a new recording; try again later.
        var postponed = false
    }

    static func finish(_ take: Take) async -> Outcome {
        // Leave out any file that isn't a playable video (a camera that failed mid-take), so one
        // bad file can't stop the rest of the take from combining or saving.
        var take = take
        var playable: [Take.Segment] = []
        for segment in take.segments where await isPlayable(take.url(of: segment)) {
            playable.append(segment)
        }
        take.segments = playable

        let backs = take.segments(of: .back)
        let fronts = take.segments(of: .front)
        guard !backs.isEmpty || !fronts.isEmpty else {
            try? FileManager.default.removeItem(at: take.folder)
            return Outcome(message: "The recording couldn't be saved")
        }

        var combined: URL?
        var message: String?
        if take.save != .angles, !backs.isEmpty, !fronts.isEmpty {
            do {
                combined = try await CombinedRenderer.render(take)
            } catch {
                if Task.isCancelled { return Outcome(postponed: true) }
                message = "Saved both angles; the combined video couldn't be made"
            }
        }

        var videos: [URL] = []
        if take.save != .combined || combined == nil {
            do {
                videos += try await angleFiles(backs, of: take, camera: .back)
                videos += try await angleFiles(fronts, of: take, camera: .front)
            } catch {
                return Outcome(postponed: true)
            }
        }
        // Added last so it's the newest item in Photos.
        if let combined { videos.append(combined) }
        guard let cover = combined ?? videos.first else { return Outcome(postponed: true) }
        let thumbnail = await thumbnail(of: cover)

        #if DEBUG
        keepForDiagnostics(take, videos: videos)
        if take.isTest == true {
            // Self-test recordings never reach Photos; the copy in LastTake is for checking.
            try? FileManager.default.removeItem(at: take.folder)
            return Outcome(thumbnail: thumbnail, message: message)
        }
        #endif

        guard await canAddToLibrary() else {
            take.forgetInfo()
            return Outcome(thumbnail: thumbnail, message: "Photos access is off, so the videos are in the Files app")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in videos {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    // Moving instead of copying: no second copy of large files on a full iPhone.
                    options.shouldMoveFile = true
                    request.addResource(with: .video, fileURL: url, options: options)
                    request.creationDate = take.date
                }
            }
            try? FileManager.default.removeItem(at: take.folder)
        } catch {
            take.forgetInfo()
            return Outcome(thumbnail: thumbnail, message: "Couldn't save to Photos; the videos are in the Files app")
        }
        return Outcome(thumbnail: thumbnail, message: message)
    }

    /// One file per camera: the file itself, or its lens-switch pieces joined into one
    /// (without re-encoding). If joining fails, the pieces are saved as they are.
    private static func angleFiles(_ segments: [Take.Segment], of take: Take, camera: CameraSide) async throws -> [URL] {
        guard segments.count > 1 else { return segments.map(take.url(of:)) }
        do {
            return [try await join(segments, of: take, camera: camera)]
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return segments.map(take.url(of:))
        }
    }

    private static func join(_ segments: [Take.Segment], of take: Take, camera: CameraSide) async throws -> URL {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CombinedRenderer.RenderError.exportFailed }
        let first = segments.first?.start ?? 0
        for segment in segments {
            let asset = AVURLAsset(url: take.url(of: segment))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let at = (segment.start ?? 0) - first
            if video.segments.isEmpty { video.preferredTransform = try await source.load(.preferredTransform) }
            try CombinedRenderer.place(try await source.load(.timeRange), of: source, in: video, at: at)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                try CombinedRenderer.place(try await sound.load(.timeRange), of: sound, in: audio, at: at)
            }
        }
        if audio.segments.isEmpty { composition.removeTrack(audio) }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CombinedRenderer.RenderError.exportFailed
        }
        let url = take.folder.appendingPathComponent("\(take.id)_\(camera == .back ? "Back" : "Front")-Joined.mov")
        try? FileManager.default.removeItem(at: url)
        try await CombinedRenderer.export(exporter, to: url)
        return url
    }

    #if DEBUG
    /// Debug builds keep a copy of the last take (if it's small) in Library/Caches/LastTake, so it
    /// can be pulled off a connected iPhone and checked: sync, orientation, the combined video.
    private static func keepForDiagnostics(_ take: Take, videos: [URL]) {
        let files = FileManager.default
        let folder = URL.cachesDirectory.appendingPathComponent("LastTake", isDirectory: true)
        try? files.removeItem(at: folder)
        // Every camera piece too (not just the joined files), to check how they line up.
        let pieces = take.segments.map(take.url(of:)).filter { !videos.contains($0) }
        let all = videos + pieces
        let size = all.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard size < 300_000_000, (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        for url in all + [take.folder.appendingPathComponent("take.json")] {
            try? files.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }
    #endif

    private static func isPlayable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0.1
    }

    private static func canAddToLibrary() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private static func thumbnail(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
