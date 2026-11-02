import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Makes the combined video (back and front in one frame, as you saw it) from the two camera
/// files after recording. Doing it afterwards instead of live leaves the whole heat budget to
/// the cameras while you shoot. Layout changes made while recording are replayed.
enum CombinedRenderer {
    enum RenderError: Error { case noVideo, exportFailed }

    /// The combined video. Cancelling the task stops the export (a new recording needs the
    /// GPU and encoders more); the take is then finished later.
    static func render(_ take: Take) async throws -> URL {
        let composition = AVMutableComposition()
        var videoTracks: [CameraSide: AVMutableCompositionTrack] = [:]
        var audioTracks: [CameraSide: AVMutableCompositionTrack] = [:]
        var transforms: [CameraSide: CGAffineTransform] = [:]
        var backSize: CGSize?
        /// Where each camera's last file ends, in seconds.
        var ends: [CameraSide: Double] = [:]

        for camera in [CameraSide.back, .front] {
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw RenderError.noVideo }
            // Every file of this camera (more than one if the lens pair was switched mid-take), at
            // the time it really started, so the two cameras stay in step.
            for segment in take.segments(of: camera) {
                let asset = AVURLAsset(url: take.url(of: segment))
                guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let at = segment.start ?? 0
                let end = try place(try await source.load(.timeRange), of: source, in: video, at: at)
                if transforms[camera] == nil {
                    transforms[camera] = try await source.load(.preferredTransform)
                    if camera == .back { backSize = try await source.load(.naturalSize) }
                }
                if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                    try place(try await sound.load(.timeRange), of: sound, in: audio, at: at)
                }
                ends[camera] = max(ends[camera] ?? 0, end)
            }
            videoTracks[camera] = video
            if audio.segments.isEmpty {
                composition.removeTrack(audio)
            } else {
                audioTracks[camera] = audio
            }
        }

        guard let backTrack = videoTracks[.back], let frontTrack = videoTracks[.front],
              let backTransform = transforms[.back], let frontTransform = transforms[.front],
              let natural = backSize else { throw RenderError.noVideo }
        let oriented = CGRect(origin: .zero, size: natural).applying(backTransform).size
        let canvas = CGSize(width: abs(oriented.width).rounded(), height: abs(oriented.height).rounded())

        // The camera knows portrait from landscape for certain; trust it over the motion sensor.
        var orientation = take.orientation
        if orientation.isLandscape != (canvas.width > canvas.height) {
            orientation = canvas.width > canvas.height ? .landscapeLeft : .portrait
        }

        let instruction = DualInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            backTrackID: backTrack.trackID, frontTrackID: frontTrack.trackID,
            backTransform: backTransform, frontTransform: frontTransform,
            backEnds: ends[.back] ?? 0, frontEnds: ends[.front] ?? 0,
            timeline: take.timeline, orientation: orientation, canvas: canvas)

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = DualCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(take.mode.fps))
        video.renderSize = canvas
        video.instructions = [instruction]

        let preset = take.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RenderError.exportFailed
        }
        exporter.videoComposition = video
        exporter.audioMix = audioMix(back: audioTracks[.back], front: audioTracks[.front],
                                     timeline: take.timeline, frontEnds: ends[.front] ?? 0)
        let url = take.combinedURL
        try? FileManager.default.removeItem(at: url)
        try await export(exporter, to: url)
        return url
    }

    static func export(_ exporter: AVAssetExportSession, to url: URL) async throws {
        if #available(iOS 18.0, *) {
            try await exporter.export(to: url, as: .mov)
        } else {
            exporter.outputURL = url
            exporter.outputFileType = .mov
            await withTaskCancellationHandler {
                await exporter.export()
            } onCancel: {
                exporter.cancelExport()
            }
            if exporter.status == .cancelled { throw CancellationError() }
            guard exporter.status == .completed else { throw exporter.error ?? RenderError.exportFailed }
        }
    }

    /// Puts `range` of `source` at `seconds` on the take's clock, after whatever the track
    /// already holds, so the cameras stay in step: a gap (the moment a lens switch takes) stays a
    /// gap, and a tiny overlap is trimmed. Returns where it ends, in seconds.
    ///
    /// The gap can't be filled here by stretching the last frame: exports fail with -12780 on a
    /// stretched single frame. The combined video holds the frame while drawing instead.
    @discardableResult
    static func place(_ range: CMTimeRange, of source: AVAssetTrack, in track: AVMutableCompositionTrack,
                      at seconds: Double) throws -> Double {
        var range = range
        var at = CMTime(seconds: seconds, preferredTimescale: 600)
        let end = track.segments.isEmpty ? CMTime.zero : track.timeRange.end
        if at < end {
            let overlap = end - at
            range = CMTimeRange(start: range.start + overlap, duration: range.duration - overlap)
            at = end
        } else if at > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        guard range.duration > .zero else { return end.seconds }
        try track.insertTimeRange(range, of: source, at: at)
        return (at + range.duration).seconds
    }

    /// Plays the microphone facing the main camera, crossfading when you swap.
    private static func audioMix(back: AVMutableCompositionTrack?, front: AVMutableCompositionTrack?,
                                 timeline: LayoutTimeline, frontEnds: Double) -> AVAudioMix? {
        guard let back, let front else { return nil }
        let backParameters = AVMutableAudioMixInputParameters(track: back)
        let frontParameters = AVMutableAudioMixInputParameters(track: front)
        var switches = timeline.audioSwitches.filter { $0.time < frontEnds }
        // If the front file ended early (to cool down), the back microphone takes over.
        if switches.last?.front == true { switches.append((frontEnds, false)) }

        let fade = CMTime(seconds: 0.25, preferredTimescale: 600)
        for (index, change) in switches.enumerated() {
            let frontLevel: Float = change.front ? 1 : 0
            let at = CMTime(seconds: change.time, preferredTimescale: 600)
            if index == 0 {
                frontParameters.setVolume(frontLevel, at: .zero)
                backParameters.setVolume(1 - frontLevel, at: .zero)
            } else {
                let range = CMTimeRange(start: at, duration: fade)
                frontParameters.setVolumeRamp(fromStartVolume: 1 - frontLevel, toEndVolume: frontLevel, timeRange: range)
                backParameters.setVolumeRamp(fromStartVolume: frontLevel, toEndVolume: 1 - frontLevel, timeRange: range)
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [backParameters, frontParameters]
        return mix
    }
}

/// Everything the compositor needs for one combined video. AVFoundation creates the
/// compositor itself, so the details travel on the instruction.
final class DualInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let backTrackID: CMPersistentTrackID
    let frontTrackID: CMPersistentTrackID
    let backTransform: CGAffineTransform
    let frontTransform: CGAffineTransform
    /// Where each camera's last file ends: a missing frame before then is a lens-switch gap.
    let backEnds: Double
    let frontEnds: Double
    let timeline: LayoutTimeline
    let orientation: RecordOrientation
    let canvas: CGSize

    init(timeRange: CMTimeRange, backTrackID: CMPersistentTrackID, frontTrackID: CMPersistentTrackID,
         backTransform: CGAffineTransform, frontTransform: CGAffineTransform,
         backEnds: Double, frontEnds: Double,
         timeline: LayoutTimeline, orientation: RecordOrientation, canvas: CGSize) {
        self.timeRange = timeRange
        self.backTrackID = backTrackID
        self.frontTrackID = frontTrackID
        self.backTransform = backTransform
        self.frontTransform = frontTransform
        self.backEnds = backEnds
        self.frontEnds = frontEnds
        self.timeline = timeline
        self.orientation = orientation
        self.canvas = canvas
        requiredSourceTrackIDs = [NSNumber(value: backTrackID), NSNumber(value: frontTrackID)]
    }
}

/// Draws each frame of the combined video with Core Image on the GPU.
final class DualCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Low-priority GPU work, so the live cameras stay smooth while a take is being combined.
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    /// The last picture from each camera, held through a lens-switch gap instead of going black.
    private let lock = NSLock()
    private var lastBack: CIImage?
    private var lastFront: CIImage?

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                      kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? DualInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "DualShot", code: 1))
            return
        }
        var back = request.sourceFrame(byTrackID: instruction.backTrackID)
            .map { Self.upright(CIImage(cvPixelBuffer: $0), transform: instruction.backTransform) }
        var front = request.sourceFrame(byTrackID: instruction.frontTrackID)
            .map { Self.upright(CIImage(cvPixelBuffer: $0), transform: instruction.frontTransform) }
        let time = request.compositionTime.seconds
        lock.lock()
        if let back { lastBack = back } else if time < instruction.backEnds { back = lastBack }
        if let front { lastFront = front } else if time < instruction.frontEnds { front = lastFront }
        lock.unlock()

        let canvas = instruction.canvas
        let bounds = CGRect(origin: .zero, size: canvas)
        var image = CIImage(color: .black).cropped(to: bounds)

        if let back, let front {
            let frames = instruction.timeline.frames(at: request.compositionTime.seconds,
                                                     canvas: canvas, orientation: instruction.orientation)
            let backLayer = (back, frames.back, frames.backRadius)
            let frontLayer = (front, frames.front, frames.frontRadius)
            for (picture, rect, radius) in frames.frontOnTop ? [backLayer, frontLayer] : [frontLayer, backLayer] {
                image = Self.place(picture, in: rect, radius: radius, over: image, canvas: canvas)
            }
        } else if let only = back ?? front {
            // One camera has ended (the front can stop early to cool down): it fills the frame.
            image = Self.place(only, in: bounds, radius: 0, over: image, canvas: canvas)
        }

        context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    /// Applies a track's rotation (and mirroring, if any) so the picture is upright,
    /// with its corner at the origin.
    static func upright(_ image: CIImage, transform t: CGAffineTransform) -> CIImage {
        guard !t.isIdentity else { return image }
        let size = image.extent.size
        let display = CGRect(origin: .zero, size: size).applying(t)
        // Track transforms use a top-left origin; Core Image uses bottom-left.
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let toBottomLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height)
        let turned = image.transformed(by: toTopLeft.concatenating(t).concatenating(toBottomLeft))
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    }

    /// Scales `picture` to fill `rect` (top-left origin), crops it, rounds its corners and
    /// draws it over `background`.
    static func place(_ picture: CIImage, in rect: CGRect, radius: CGFloat, over background: CIImage,
                      canvas: CGSize) -> CIImage {
        let target = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        guard target.width > 1, target.height > 1 else { return background }
        let scale = max(target.width / picture.extent.width, target.height / picture.extent.height)
        let scaled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let moved = scaled.transformed(by: CGAffineTransform(translationX: target.midX - scaled.extent.midX,
                                                             y: target.midY - scaled.extent.midY))
            .cropped(to: target)
        guard radius > 0.5 else { return moved.composited(over: background) }
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = target
        mask.radius = Float(radius)
        mask.color = .white
        guard let maskImage = mask.outputImage else { return moved.composited(over: background) }
        return moved.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: maskImage,
        ])
    }
}
