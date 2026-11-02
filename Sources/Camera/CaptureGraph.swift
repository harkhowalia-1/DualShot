import AVFoundation

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264

    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

/// How the files are written. None of this changes what the cameras can do.
struct RecordingOptions: Equatable {
    var codec: VideoCodec
    var mirrorFront = true
    var audio = true
    /// The highest frame rate this resolution and lens can run. The cameras are set up for it
    /// from the start, so switching between 24, 30 and 60 only retimes them.
    var ceilingFPS = 30
    /// Photo mode: both cameras feed photo outputs (4:3, the largest photos multi-camera allows)
    /// instead of movie files.
    var photo = false
}

/// How photos are saved.
enum PhotoFormat: String, Codable, CaseIterable, Identifiable {
    case heif, jpeg

    var id: String { rawValue }
    var label: String { self == .heif ? "HEIF" : "JPEG" }
}

/// Front and back stills taken at the same moment, plus how the phone was held.
struct DualPhoto {
    var back: Data?
    var front: Data?
}

struct SessionCosts {
    var hardware: Float
    var pressure: Float
}

enum GraphError: Error {
    case noCamera, noFormat, cannotConnect
}

/// The back camera's zoom range and buttons, read on the session queue so the screen never
/// waits on AVFoundation.
struct BackZoom {
    var multiplier: CGFloat
    var minFactor: CGFloat
    var maxFactor: CGFloat
    var stops: [ZoomStop]
}

struct CameraInfo {
    var hasTorch: Bool
    var zoom: BackZoom?
}

/// Owns every AVFoundation object. Everything here runs on `queue`, except the preview
/// layers, which the viewfinder hosts. The screen's code never reads a camera directly:
/// a camera busy reconfiguring would make it wait, and the UI would stutter.
///
/// Front and back run in one `AVCaptureMultiCamSession`, each wired by hand to its own
/// movie file output, so every recording makes two independent files on one shared clock.
final class CaptureGraph: NSObject, @unchecked Sendable {
    let session: AVCaptureMultiCamSession
    let backPreview: AVCaptureVideoPreviewLayer
    let frontPreview: AVCaptureVideoPreviewLayer
    let queue = DispatchQueue(label: "dualshot.session")

    private let backOutput = AVCaptureMovieFileOutput()
    private let frontOutput = AVCaptureMovieFileOutput()
    private let backPhoto = AVCapturePhotoOutput()
    private let frontPhoto = AVCapturePhotoOutput()
    private var photoDelegates: [PhotoPairDelegate] = []
    private(set) var backDevice: AVCaptureDevice?
    private(set) var frontDevice: AVCaptureDevice?
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    /// What the graph is set up for, so changes can touch only what differs.
    private var current: (plan: DualPlan, options: RecordingOptions)?
    /// The top frame rate the inputs are budgeted for (`videoMinFrameDurationOverride`).
    private var overrideFPS = 30
    /// Horizon-level angles for recordings; previews are always portrait.
    private var backRotation: AVCaptureDevice.RotationCoordinator?
    private var frontRotation: AVCaptureDevice.RotationCoordinator?
    /// The angles of the take being recorded, kept so a lens switch mid-take matches them.
    private var takeAngles: (back: CGFloat, front: CGFloat)?
    private var pressureObservations: [NSKeyValueObservation] = []

    /// The worse of the two cameras' system pressure, reported from any thread.
    var onPressureChange: (@Sendable (AVCaptureDevice.SystemPressureState.Level) -> Void)?

    /// The preview layers belong to the viewfinder's views (so Core Animation can move them
    /// cheaply); the graph only feeds them. Call on the main thread.
    init(backPreview: AVCaptureVideoPreviewLayer, frontPreview: AVCaptureVideoPreviewLayer) {
        let session = AVCaptureMultiCamSession()
        // The app manages its own audio session (see AudioSetup).
        session.automaticallyConfiguresApplicationAudioSession = false
        self.session = session
        self.backPreview = backPreview
        self.frontPreview = frontPreview
        for layer in [backPreview, frontPreview] {
            layer.setSessionWithNoConnection(session)
            layer.videoGravity = .resizeAspectFill
        }
        super.init()
    }

    /// Runs `work` on the session queue.
    func perform<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    func startRunning() {
        if !session.isRunning { session.startRunning() }
    }

    func stopRunning() {
        if session.isRunning { session.stopRunning() }
    }

    // MARK: - Devices

    static var frontCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    static func backCamera(_ lens: BackLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
    }

    /// Back cameras this iPhone allows next to the front one, best first.
    static func lensesAllowedWithFront() -> [BackLens] {
        guard let front = frontCamera else { return [] }
        let sets = AVCaptureDevice.DiscoverySession(deviceTypes: BackLens.allCases.map(\.deviceType),
                                                    mediaType: .video, position: .unspecified)
            .supportedMultiCamDeviceSets
        return BackLens.allCases.filter { lens in
            guard let back = backCamera(lens) else { return false }
            return sets.contains { set in
                set.contains { $0.uniqueID == back.uniqueID } && set.contains { $0.uniqueID == front.uniqueID }
            }
        }
    }

    /// The zoom range a back camera covers, labelled like the native camera (".5×–2×").
    static func zoomRange(of lens: BackLens) -> String {
        guard let device = backCamera(lens) else { return lens.fallbackZoomRange }
        let m = device.displayZoomMultiplier
        let longest = max(2, (device.virtualDeviceSwitchOverVideoZoomFactors.last.map { CGFloat($0.doubleValue) } ?? 1) * m)
        func label(_ value: CGFloat) -> String {
            value < 1 ? String(format: ".%d×", Int((value * 10).rounded())) : "\(Int(value.rounded()))×"
        }
        return "\(label(m))–\(label(longest))"
    }

    /// A camera's zoom buttons, as the native camera shows them (.5, 1, 2, 3).
    static func zoomStops(for device: AVCaptureDevice, lens: BackLens?) -> [ZoomStop] {
        let m = device.displayZoomMultiplier
        let factors: [CGFloat] = [1] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var stops = factors.map { ZoomStop(display: $0 * m, deviceFactor: $0, lens: lens) }
        // The native camera always offers a 2× crop off the main camera.
        if !stops.contains(where: { abs($0.display - 2) < 0.05 }), device.maxAvailableVideoZoomFactor >= 2 / m {
            stops.append(ZoomStop(display: 2, deviceFactor: 2 / m, lens: lens))
        }
        return stops
    }

    // MARK: - Probe

    /// Tries each back camera at each size and frame rate and keeps what the hardware can run.
    /// Takes a few seconds, so the result is cached per iPhone and iOS version.
    func probe() -> [DualPlan] {
        let lenses = Self.lensesAllowedWithFront()
        let modes = [VideoMode(height: 1080, fps: 30), VideoMode(height: 1080, fps: 60),
                     VideoMode(height: 2160, fps: 30), VideoMode(height: 2160, fps: 60)]
        var plans = probe(lenses: lenses, modes: modes)
        if plans.isEmpty {
            plans = probe(lenses: lenses, modes: [VideoMode(height: 720, fps: 30)])
        }
        current = nil
        return plans
    }

    private func probe(lenses: [BackLens], modes: [VideoMode]) -> [DualPlan] {
        var plans: [DualPlan] = []
        for lens in lenses {
            guard let back = Self.backCamera(lens), let front = Self.frontCamera else { continue }
            var tooMuch: [VideoMode] = []
            for mode in modes {
                // If a smaller mode was already over budget, a bigger one is too.
                if tooMuch.contains(where: { $0.height <= mode.height && $0.fps <= mode.fps }) { continue }
                guard FormatMatcher.format(on: back, height: mode.height, fps: mode.fps) != nil,
                      let frontFormat = FormatMatcher.format(on: front, height: mode.height, fps: mode.fps, orLower: true),
                      let frontHeight = FormatMatcher.shortSide(of: frontFormat) else { continue }
                var plan = DualPlan(mode: mode, backLens: lens, frontHeight: frontHeight, hardwareCost: 0, pressureCost: 0)
                let options = RecordingOptions(codec: .hevc, audio: false, ceilingFPS: mode.fps)
                guard let costs = try? configure(plan, options: options) else { continue }
                guard costs.hardware <= 1 else {
                    tooMuch.append(mode)
                    continue
                }
                plan.hardwareCost = costs.hardware
                plan.pressureCost = costs.pressure
                plans.append(plan)
            }
        }
        return plans
    }

    // MARK: - Configuration

    /// Builds the whole graph for `plan` and returns what it costs. Runs on `queue`.
    @discardableResult
    func configure(_ plan: DualPlan, options: RecordingOptions) throws -> SessionCosts {
        guard let back = Self.backCamera(plan.backLens), let front = Self.frontCamera else { throw GraphError.noCamera }
        let fps = plan.mode.fps
        let ceiling = options.photo ? fps : max(fps, options.ceilingFPS)
        let backFormat = options.photo ? FormatMatcher.photoFormat(on: back, fps: fps)
            : pickFormat(on: back, height: plan.mode.height, fps: fps, ceiling: ceiling, exact: true)
        let frontFormat = options.photo ? FormatMatcher.photoFormat(on: front, fps: fps)
            : pickFormat(on: front, height: plan.frontHeight, fps: fps, ceiling: ceiling, exact: false)
        guard let backFormat, let frontFormat else { throw GraphError.noFormat }

        session.beginConfiguration()
        do {
            try build(back: back, backFormat: backFormat, front: front, frontFormat: frontFormat,
                      fps: fps, ceiling: ceiling, options: options)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        current = (plan, options)
        return costs
    }

    /// Moves the running graph to `plan` with as little disruption as the change allows, like the
    /// native camera:
    /// - another frame rate at the same size only retimes the cameras: nothing restarts;
    /// - another size swaps formats in place: exposure, focus and zoom carry on;
    /// - another back lens or microphone setup rebuilds.
    /// Runs on `queue`.
    @discardableResult
    func update(to plan: DualPlan, options: RecordingOptions) throws -> SessionCosts {
        guard let current, current.plan.backLens == plan.backLens, current.options.audio == options.audio,
              current.options.mirrorFront == options.mirrorFront, current.options.photo == options.photo, !options.photo,
              let back = backDevice, let front = frontDevice, let backInput, let frontInput else {
            return try configure(plan, options: options)
        }
        let fps = plan.mode.fps

        if current.plan.mode.height == plan.mode.height, current.plan.frontHeight == plan.frontHeight,
           current.options.codec == options.codec, fps <= overrideFPS,
           Self.supports(back.activeFormat, fps), Self.supports(front.activeFormat, fps) {
            retime(back, to: fps)
            retime(front, to: fps)
            self.current = (plan, options)
            return costs
        }

        let ceiling = max(fps, options.ceilingFPS)
        guard let backFormat = pickFormat(on: back, height: plan.mode.height, fps: fps, ceiling: ceiling, exact: true),
              let frontFormat = pickFormat(on: front, height: plan.frontHeight, fps: fps, ceiling: ceiling, exact: false) else {
            throw GraphError.noFormat
        }
        let formatsChanged = backFormat != back.activeFormat || frontFormat != front.activeFormat
        session.beginConfiguration()
        do {
            try set(backFormat, fps: fps, on: back)
            try set(frontFormat, fps: fps, on: front)
            setOverride(fps: fps, ceiling: ceiling, backFormat: backFormat, frontFormat: frontFormat,
                        backInput: backInput, frontInput: frontInput)
            if options.codec != current.options.codec || formatsChanged {
                configureFile(backOutput, format: backFormat, mirrored: false, codec: options.codec)
                configureFile(frontOutput, format: frontFormat, mirrored: options.mirrorFront, codec: options.codec)
            }
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        // A format other than the measured one can cost more; if that tips the budget, rebuild.
        guard session.hardwareCost <= 1 else { return try configure(plan, options: options) }
        self.current = (plan, options)
        return costs
    }

    private var costs: SessionCosts {
        SessionCosts(hardware: session.hardwareCost, pressure: session.systemPressureCost)
    }

    /// The format for `fps`, preferring one that can also run `ceiling` so later frame-rate
    /// changes need no restart. `exact` keeps the size; otherwise up to `height` (front camera).
    private func pickFormat(on device: AVCaptureDevice, height: Int, fps: Int, ceiling: Int, exact: Bool) -> AVCaptureDevice.Format? {
        if ceiling > fps, let format = FormatMatcher.format(on: device, height: height, fps: ceiling),
           Self.supports(format, fps) {
            return format
        }
        return FormatMatcher.format(on: device, height: height, fps: fps, orLower: !exact)
    }

    private func build(back: AVCaptureDevice, backFormat: AVCaptureDevice.Format,
                       front: AVCaptureDevice, frontFormat: AVCaptureDevice.Format,
                       fps: Int, ceiling: Int, options: RecordingOptions) throws {
        for connection in session.connections { session.removeConnection(connection) }
        for input in session.inputs { session.removeInput(input) }
        for output in [backOutput, frontOutput, backPhoto, frontPhoto] as [AVCaptureOutput] where !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw GraphError.cannotConnect }
            session.addOutputWithNoConnections(output)
        }

        let backInput = try AVCaptureDeviceInput(device: back)
        let frontInput = try AVCaptureDeviceInput(device: front)
        guard session.canAddInput(backInput), session.canAddInput(frontInput) else { throw GraphError.cannotConnect }
        session.addInputWithNoConnections(backInput)
        session.addInputWithNoConnections(frontInput)

        guard let backPort = backInput.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first,
              let frontPort = frontInput.ports(for: .video, sourceDeviceType: front.deviceType, sourceDevicePosition: .front).first
        else { throw GraphError.cannotConnect }

        if options.photo {
            try connect([backPort], to: backPhoto)
            try connect([frontPort], to: frontPhoto)
        } else {
            try connect([backPort], to: backOutput)
            try connect([frontPort], to: frontOutput)
        }
        try connect(backPort, to: backPreview)
        try connect(frontPort, to: frontPreview)

        // Formats go on after the inputs are in, so the session doesn't pick its own.
        try set(backFormat, fps: fps, on: back)
        try set(frontFormat, fps: fps, on: front)
        setOverride(fps: fps, ceiling: ceiling, backFormat: backFormat, frontFormat: frontFormat,
                    backInput: backInput, frontInput: frontInput)

        if options.photo {
            configurePhoto(backPhoto, format: backFormat, mirrored: false)
            configurePhoto(frontPhoto, format: frontFormat, mirrored: options.mirrorFront)
        } else {
            if options.audio { connectMicrophones() }
            configureFile(backOutput, format: backFormat, mirrored: false, codec: options.codec)
            configureFile(frontOutput, format: frontFormat, mirrored: options.mirrorFront, codec: options.codec)
        }

        self.backInput = backInput
        self.frontInput = frontInput
        backDevice = back
        frontDevice = front
        backRotation = AVCaptureDevice.RotationCoordinator(device: back, previewLayer: nil)
        frontRotation = AVCaptureDevice.RotationCoordinator(device: front, previewLayer: nil)
        observePressure(on: [back, front])
    }

    /// The hardware budget counts each camera's top frame rate. Budgeting for the highest rate
    /// this setting can run means 24 ↔ 30 ↔ 60 later costs nothing; otherwise only for `fps`.
    private func setOverride(fps: Int, ceiling: Int, backFormat: AVCaptureDevice.Format, frontFormat: AVCaptureDevice.Format,
                             backInput: AVCaptureDeviceInput, frontInput: AVCaptureDeviceInput) {
        overrideFPS = Self.supports(backFormat, ceiling) && Self.supports(frontFormat, ceiling) ? ceiling : fps
        let duration = CMTime(value: 1, timescale: CMTimeScale(overrideFPS))
        backInput.videoMinFrameDurationOverride = duration
        frontInput.videoMinFrameDurationOverride = duration
    }

    /// Swaps the back camera for another lens pair, leaving the front camera and microphones
    /// running. The back file must be closed first: taking its camera away would end it.
    /// Runs on `queue`.
    @discardableResult
    func switchBack(to plan: DualPlan, codec: VideoCodec) throws -> SessionCosts {
        let fps = plan.mode.fps
        let photo = current?.options.photo ?? false
        guard let back = Self.backCamera(plan.backLens), let front = frontDevice,
              let format = photo ? FormatMatcher.photoFormat(on: back, fps: fps)
                : pickFormat(on: back, height: plan.mode.height, fps: fps, ceiling: overrideFPS, exact: true) else {
            throw GraphError.noFormat
        }
        session.beginConfiguration()
        do {
            if let backInput { session.removeInput(backInput) }
            let input = try AVCaptureDeviceInput(device: back)
            guard session.canAddInput(input) else { throw GraphError.cannotConnect }
            session.addInputWithNoConnections(input)
            guard let port = input.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first
            else { throw GraphError.cannotConnect }
            try connect([port], to: photo ? backPhoto : backOutput)
            try connect(port, to: backPreview)
            try set(format, fps: fps, on: back)
            let budget = Self.supports(format, overrideFPS) ? overrideFPS : fps
            input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: CMTimeScale(budget))
            if photo {
                configurePhoto(backPhoto, format: format, mirrored: false)
            } else {
                configureFile(backOutput, format: format, mirrored: false, codec: codec)
            }
            // Mid-take, the new back file keeps the take's orientation.
            if let angle = takeAngles?.back, let connection = backOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            backInput = input
            backDevice = back
            backRotation = AVCaptureDevice.RotationCoordinator(device: back, previewLayer: nil)
            observePressure(on: [back, front])
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        if let options = current?.options { current = (plan, options) }
        return costs
    }

    private func connect(_ ports: [AVCaptureInput.Port], to output: AVCaptureOutput) throws {
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard session.canAddConnection(connection) else { throw GraphError.cannotConnect }
        session.addConnection(connection)
    }

    private func connect(_ port: AVCaptureInput.Port, to layer: AVCaptureVideoPreviewLayer) throws {
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else { throw GraphError.cannotConnect }
        session.addConnection(connection)
        // The screen is always portrait, so the preview always turns to portrait (90°), for both
        // cameras. Asking a rotation coordinator instead fails while the view isn't on screen yet.
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }

    /// By default the microphone's all-around feed goes into both files. The directional feeds
    /// (the back file hearing the scene, the front file the person holding the phone) left the
    /// front file waiting for sound that never came on the iPhone 14 Pro, so it never started;
    /// they stay available behind a debug switch for testing.
    private func connectMicrophones() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInputWithNoConnections(input)
        let anyPort = input.ports.first { $0.mediaType == .audio }
        let backMic = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .back).first
        let frontMic = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .front).first
        switch Self.micWiring {
        case .beamformed:
            if let port = backMic ?? anyPort { try? connect([port], to: backOutput) }
            if let port = frontMic ?? anyPort { try? connect([port], to: frontOutput) }
        case .shared:
            let omni = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified).first
            guard let port = omni ?? anyPort else { return }
            try? connect([port], to: backOutput)
            // If one feed can't go to two files, the front file records picture only.
            try? connect([port], to: frontOutput)
        }
    }

    enum MicWiring: String {
        /// The front file hears the person holding the phone, the back file the scene.
        case beamformed
        /// The all-around feed into both files.
        case shared
    }

    static var micWiring: MicWiring {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MicWiring"), i + 1 < args.count, let wiring = MicWiring(rawValue: args[i + 1]) {
            return wiring
        }
        #endif
        return .shared
    }

    static func supports(_ format: AVCaptureDevice.Format, _ fps: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) - 0.01
        }
    }

    private func set(_ format: AVCaptureDevice.Format, fps: Int, on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Setting the same format again would still restart the camera.
        if device.activeFormat != format { device.activeFormat = format }
        // A steady frame rate keeps the two files in step, frame for frame.
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// Changes a running camera's frame rate without stopping anything.
    private func retime(_ device: AVCaptureDevice, to fps: Int) {
        guard Self.supports(device.activeFormat, fps), (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func configureFile(_ output: AVCaptureMovieFileOutput, format: AVCaptureDevice.Format,
                               mirrored: Bool, codec: VideoCodec) {
        // Written in 5-second pieces: if the app is killed or the iPhone overheats,
        // everything up to the last few seconds is still playable.
        output.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported, format.isVideoStabilizationModeSupported(.standard) {
            connection.preferredVideoStabilizationMode = .standard
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if output.availableVideoCodecTypes.contains(codec.avCodec) {
            output.setOutputSettings([AVVideoCodecKey: codec.avCodec], for: connection)
        }
    }

    private func configurePhoto(_ output: AVCapturePhotoOutput, format: AVCaptureDevice.Format, mirrored: Bool) {
        // Allow the largest photo this format can take; each shot asks for it.
        if let largest = format.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = largest
        }
        output.maxPhotoQualityPrioritization = .balanced
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// The photo size each camera takes in photo mode, in megapixels (for the Format control).
    func photoMegapixels() -> (back: Double, front: Double) {
        func mp(_ output: AVCapturePhotoOutput) -> Double { Double(output.maxPhotoDimensions.width * output.maxPhotoDimensions.height) / 1_000_000 }
        return (mp(backPhoto), mp(frontPhoto))
    }

    /// Takes a photo with both cameras at the same moment, upright for however the phone is held.
    func capturePhotos(format: PhotoFormat, flash: Bool, completion: @escaping @Sendable (DualPhoto) -> Void) {
        let delegate = PhotoPairDelegate { [weak self] photo in
            completion(photo)
            self?.queue.async { self?.photoDelegates.removeAll { $0.done } }
        }
        photoDelegates.append(delegate)
        for (output, rotation, isBack) in [(backPhoto, backRotation, true), (frontPhoto, frontRotation, false)] {
            if let connection = output.connection(with: .video), let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let codec: AVVideoCodecType = format == .heif && output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced
            if isBack, flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            delegate.expect(isBack: isBack, id: settings.uniqueID)
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - What the screen needs to know

    /// Read on the queue, then handed to the screen.
    func info() -> CameraInfo {
        guard let back = backDevice else { return CameraInfo(hasTorch: false, zoom: nil) }
        let zoom = BackZoom(multiplier: back.displayZoomMultiplier,
                            minFactor: back.minAvailableVideoZoomFactor,
                            maxFactor: back.maxAvailableVideoZoomFactor,
                            stops: Self.zoomStops(for: back, lens: current?.plan.backLens))
        return CameraInfo(hasTorch: back.hasTorch, zoom: zoom)
    }

    #if DEBUG
    func diagnostics() -> [String: Any] {
        var info: [String: Any] = [
            "sessionRunning": session.isRunning,
            "sessionInterrupted": session.isInterrupted,
            "previewAngles": [backPreview.connection?.videoRotationAngle ?? -1, frontPreview.connection?.videoRotationAngle ?? -1],
            "previewMirrored": [backPreview.connection?.isVideoMirrored ?? false, frontPreview.connection?.isVideoMirrored ?? false],
            "captureAngles": [backRotation?.videoRotationAngleForHorizonLevelCapture ?? -1,
                              frontRotation?.videoRotationAngleForHorizonLevelCapture ?? -1],
            "budgetFPS": overrideFPS,
        ]
        for (name, device) in [("back", backDevice), ("front", frontDevice)] {
            guard let device else { continue }
            let dims = device.activeFormat.formatDescription.dimensions
            let duration = device.activeVideoMinFrameDuration.seconds
            info[name] = ["type": device.deviceType.rawValue, "format": "\(dims.width)x\(dims.height)",
                          "fps": duration > 0 ? 1 / duration : -1, "binned": device.activeFormat.isVideoBinned,
                          "pressure": device.systemPressureState.level.rawValue]
        }
        return info
    }
    #endif

    // MARK: - Recording

    /// Starts both files, upright for however the phone is held. Returns the angles used.
    @discardableResult
    func startRecording(back backURL: URL, front frontURL: URL,
                        delegate: AVCaptureFileOutputRecordingDelegate) -> (back: CGFloat, front: CGFloat) {
        let angles = (back: backRotation?.videoRotationAngleForHorizonLevelCapture ?? 90,
                      front: frontRotation?.videoRotationAngleForHorizonLevelCapture ?? 90)
        takeAngles = angles
        for (output, angle) in [(backOutput, angles.back), (frontOutput, angles.front)] {
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        backOutput.startRecording(to: backURL, recordingDelegate: delegate)
        frontOutput.startRecording(to: frontURL, recordingDelegate: delegate)
        return angles
    }

    /// Starts the next files of a take after a lens switch, at the take's orientation.
    func resume(back backURL: URL, front frontURL: URL?, delegate: AVCaptureFileOutputRecordingDelegate) {
        if let angles = takeAngles {
            for (output, angle) in [(backOutput, angles.back), (frontOutput, angles.front)] {
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
        backOutput.startRecording(to: backURL, recordingDelegate: delegate)
        if let frontURL { frontOutput.startRecording(to: frontURL, recordingDelegate: delegate) }
    }

    /// Stops both files. Asked unconditionally: a file that hasn't begun writing yet reports it
    /// isn't recording, and skipping it would leave it to start (and never stop) later.
    func stopRecording() {
        backOutput.stopRecording()
        frontOutput.stopRecording()
    }

    /// Closes the front file cleanly while the back keeps recording.
    func stopFront() {
        if frontOutput.isRecording { frontOutput.stopRecording() }
    }

    func takeEnded() {
        takeAngles = nil
    }

    /// Changes both cameras' frame rate without stopping. Used to cool down.
    func setFrameRate(_ fps: Int) {
        for device in [backDevice, frontDevice].compactMap({ $0 }) { retime(device, to: fps) }
    }

    // MARK: - Torch, zoom and focus

    func setTorch(_ on: Bool) {
        guard let device = backDevice, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        if on, device.isTorchModeSupported(.on) {
            try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else if device.isTorchModeSupported(.off) {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard let device = backDevice, (try? device.lockForConfiguration()) != nil else { return }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if animated {
            device.ramp(toVideoZoomFactor: clamped, withRate: 12)
        } else {
            device.videoZoomFactor = clamped
        }
        device.unlockForConfiguration()
    }

    /// Tap to focus and expose; goes back to continuous when the scene changes.
    func focus(at devicePoint: CGPoint, onBack: Bool) {
        guard let device = onBack ? backDevice : frontDevice, (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
    }

    func resumeContinuousFocus() {
        for device in [backDevice, frontDevice].compactMap({ $0 }) {
            guard (try? device.lockForConfiguration()) != nil else { continue }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
        }
    }

    // MARK: - Heat

    private func observePressure(on devices: [AVCaptureDevice]) {
        pressureObservations = devices.map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] _, _ in
                let worst = devices.map(\.systemPressureState.level).max { PressureLevel($0) < PressureLevel($1) }
                if let worst { self?.onPressureChange?(worst) }
            }
        }
    }
}

extension AVCaptureDevice {
    /// Converts zoom factors to the numbers the native camera shows (the ultra wide is .5×).
    var displayZoomMultiplier: CGFloat {
        if #available(iOS 18.0, *) { return displayVideoZoomFactorMultiplier }
        return constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ? 0.5 : 1
    }
}

/// Collects the two photos of one dual shot and reports once both have arrived.
final class PhotoPairDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var backID: Int64?
    private var pending = 2
    private var photo = DualPhoto()
    private let completion: @Sendable (DualPhoto) -> Void
    private(set) var done = false

    init(completion: @escaping @Sendable (DualPhoto) -> Void) {
        self.completion = completion
    }

    func expect(isBack: Bool, id: Int64) {
        lock.lock()
        if isBack { backID = id }
        lock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        lock.lock()
        if photo.resolvedSettings.uniqueID == backID { self.photo.back = data } else { self.photo.front = data }
        lock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        lock.lock()
        pending -= 1
        let finished = pending == 0
        if finished { done = true }
        let result = photo
        lock.unlock()
        if finished { completion(result) }
    }
}
