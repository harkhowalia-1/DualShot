import AVFoundation

/// A recording size and frame rate. Both files use it, unless the front camera can't go that high.
struct VideoMode: Hashable, Codable, Identifiable, Comparable {
    /// The short side: 720, 1080 or 2160.
    var height: Int
    var fps: Int

    var id: String { "\(height)p\(fps)" }

    static let standard = VideoMode(height: 1080, fps: 30)

    /// What the top bar shows, like the native camera ("HD · 30", "4K · 60").
    var resolutionLabel: String {
        switch height {
        case 2160...: "4K"
        case 1080: "HD"
        default: "\(height)p"
        }
    }

    var label: String { "\(resolutionLabel) · \(fps)" }

    static func < (a: VideoMode, b: VideoMode) -> Bool {
        (a.height, a.fps) < (b.height, b.fps)
    }
}

/// Which back camera runs next to the front one. The multi-lens cameras switch between
/// .5×, 1× and telephoto while recording, like the native camera; the plain wide camera
/// costs less, so it can reach higher resolutions on some iPhones.
enum BackLens: String, Codable, CaseIterable {
    case triple, dualWide, dual, wide

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .triple: .builtInTripleCamera
        case .dualWide: .builtInDualWideCamera
        case .dual: .builtInDualCamera
        case .wide: .builtInWideAngleCamera
        }
    }

    /// What the pair is called in the Back Lenses choices.
    var pairName: String {
        switch self {
        case .triple: "All Three"
        case .dualWide: "Ultra Wide + Wide"
        case .dual: "Wide + Telephoto"
        case .wide: "Wide"
        }
    }

    /// The zoom range as the native camera would label it, for when the camera can't be asked.
    var fallbackZoomRange: String {
        switch self {
        case .triple: ".5×–3×"
        case .dualWide: ".5×–2×"
        case .dual: "1×–3×"
        case .wide: "1×–2×"
        }
    }
}

/// One configuration the probe found this iPhone can run, with what it costs.
struct DualPlan: Codable, Hashable {
    var mode: VideoMode
    var backLens: BackLens
    /// The front camera's short side; lower than `mode.height` when it can't match the back.
    var frontHeight: Int
    /// 0...1 is runnable. Anything above 1 never gets here.
    var hardwareCost: Float
    /// Above 1 means the iPhone can't keep it up: it heats up and has to slow down.
    var pressureCost: Float

    var isSustainable: Bool { pressureCost <= 1 }
}

/// Everything the probe learned about this iPhone, cached so later launches start instantly.
struct DualCapabilities: Codable {
    var key: String
    var plans: [DualPlan]

    /// Every mode the iPhone can record. 24 and 25 fps cost no more than 30, so they come along.
    var modes: [VideoMode] {
        var modes = Set<VideoMode>()
        for plan in plans {
            modes.insert(plan.mode)
            if plan.mode.fps == 30 {
                modes.insert(VideoMode(height: plan.mode.height, fps: 24))
                modes.insert(VideoMode(height: plan.mode.height, fps: 25))
            }
        }
        return modes.sorted()
    }

    /// The best way to record `mode`: `lens` if it was chosen and works, otherwise lens switching
    /// when it fits, otherwise the cheaper wide camera.
    func plan(for mode: VideoMode, lens: BackLens? = nil) -> DualPlan? {
        let order = BackLens.allCases
        let candidates = plans.filter { $0.mode == Self.probed(mode) }
            .sorted { order.firstIndex(of: $0.backLens)! < order.firstIndex(of: $1.backLens)! }
        let chosen = lens.flatMap { lens in candidates.first { $0.backLens == lens } }
        guard var plan = chosen ?? candidates.first(where: \.isSustainable) ?? candidates.first else { return nil }
        plan.mode = mode
        return plan
    }

    /// When no back camera covers every lens next to the front one (the 14 Pro has no triple
    /// camera in dual mode), the two pairs to choose between: ultra wide + wide, or wide + telephoto.
    func lensChoices(for mode: VideoMode) -> [BackLens] {
        let lenses = Set(plans.filter { $0.mode == Self.probed(mode) }.map(\.backLens))
        guard !lenses.contains(.triple) else { return [] }
        let pairs = [BackLens.dualWide, .dual].filter(lenses.contains)
        return pairs.count > 1 ? pairs : []
    }

    /// 24 and 25 fps were measured as 30.
    private static func probed(_ mode: VideoMode) -> VideoMode {
        mode.fps <= 30 ? VideoMode(height: mode.height, fps: 30) : mode
    }

    /// The closest mode that runs without overheating, for the "Record anyway?" choice.
    func recommendedAlternative(to mode: VideoMode) -> VideoMode? {
        let sustainable = modes.filter { plan(for: $0)?.isSustainable == true && $0 < mode }
        // Keep the resolution if a lower frame rate is enough, otherwise keep the frame rate.
        return sustainable.filter { $0.height == mode.height }.max()
            ?? sustainable.filter { $0.fps == min(mode.fps, 30) }.max()
            ?? sustainable.max()
    }

    /// Changing resolution keeps the frame rate if it can, otherwise takes the closest one.
    func mode(height: Int, keeping fps: Int) -> VideoMode {
        let options = fpsOptions(height: height)
        let pick = options.contains(fps) ? fps : options.min { abs($0 - fps) < abs($1 - fps) } ?? 30
        return VideoMode(height: height, fps: pick)
    }

    /// The fastest frame rate measured for this size and lens: the cameras are budgeted for it so
    /// frame-rate changes below it are instant.
    func ceilingFPS(height: Int, lens: BackLens) -> Int {
        plans.filter { $0.mode.height == height && $0.backLens == lens }.map(\.mode.fps).max() ?? 30
    }

    func fpsOptions(height: Int) -> [Int] {
        modes.filter { $0.height == height }.map(\.fps).sorted()
    }

    var heights: [Int] { Array(Set(modes.map(\.height))).sorted() }
}

/// Picks camera formats that work with two cameras running at once.
enum FormatMatcher {
    /// iPhone formats are listed in landscape; the width tells the size class.
    static func shortSide(of format: AVCaptureDevice.Format) -> Int? {
        switch format.formatDescription.dimensions.width {
        case 1280: 720
        case 1920: 1080
        case 3840: 2160
        default: nil
        }
    }

    /// The cheapest multi-camera format of exactly `height` that can run at `fps`.
    /// With `orLower`, the largest one up to `height` instead (for the front camera).
    static func format(on device: AVCaptureDevice, height: Int, fps: Int, orLower: Bool = false) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { format in
            guard format.isMultiCamSupported, let h = shortSide(of: format) else { return false }
            guard orLower ? h <= height : h == height else { return false }
            let subtype = format.formatDescription.mediaSubType.rawValue
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) - 0.01
            }
        }
        return usable.max { a, b in score(a, wanted: height) < score(b, wanted: height) }
    }

    /// Photo mode: the multi-camera format that takes the largest photos (4:3 preferred, like the
    /// native Photo mode), able to run at `fps`.
    static func photoFormat(on device: AVCaptureDevice, fps: Int) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            let subtype = format.formatDescription.mediaSubType.rawValue
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) - 0.01
            }
        }
        func photoPixels(_ format: AVCaptureDevice.Format) -> Int {
            format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        func score(_ format: AVCaptureDevice.Format) -> Double {
            let dims = format.formatDescription.dimensions
            let fourByThree = abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.01
            return Double(photoPixels(format)) / 1000 + (fourByThree ? 1_000_000 : 0) - Double(dims.width)
        }
        return usable.max { score($0) < score($1) }
    }

    /// Bigger is better: the right size, then 16:9, then binned (cheaper and cooler),
    /// then the lowest top frame rate (the hardware budget counts the format's maximum).
    private static func score(_ format: AVCaptureDevice.Format, wanted: Int) -> Double {
        let dims = format.formatDescription.dimensions
        let h = Double(shortSide(of: format) ?? 0)
        let widescreen = abs(Double(dims.width) / Double(dims.height) - 16.0 / 9.0) < 0.01
        let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return h * 1000
            + (widescreen ? 100 : 0)
            + (format.isVideoBinned ? 10 : 0)
            - maxFPS / 100
    }
}
