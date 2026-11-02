import AVFoundation
import SwiftUI
import UIKit

struct ZoomStop: Identifiable, Equatable {
    /// What the button shows (.5, 1, 2, 3).
    let display: CGFloat
    let deviceFactor: CGFloat
    /// The back camera this stop belongs to; picking it may switch lens pairs.
    var lens: BackLens?

    var id: CGFloat { display }
    var label: String {
        display < 1 ? String(format: ".%d", Int((display * 10).rounded())) : "\(Int(display.rounded()))"
    }
}

struct FocusMark: Equatable {
    var point: CGPoint
    var onBack: Bool
    var id: Int
}

/// Shown before recording a mode the iPhone can't keep up, or while it's already hot.
struct ForcePrompt: Identifiable, Equatable {
    let id = UUID()
    let mode: VideoMode
    /// The closest mode that runs cool, if there is one.
    let alternative: VideoMode?
    /// The mode is fine, but the iPhone is already hot.
    let alreadyHot: Bool
}

/// The camera screen's model: front and back at once, recorded to separate files.
@MainActor
@Observable
final class DualCamera: NSObject {
    enum Status: Equatable {
        case starting
        /// First launch: measuring what this iPhone can do.
        case measuring
        case ready
        case denied
        case unsupported
    }

    // MARK: UI state
    var status: Status = .starting
    var capabilities: DualCapabilities?
    var mode: VideoMode = Preferences.load(.mode) ?? .standard
    /// A size or frame rate just picked, shown right away while the cameras switch to it.
    var pendingMode: VideoMode?
    /// What the controls show: the choice just made, or what's running.
    var displayMode: VideoMode { pendingMode ?? mode }
    /// A lens pair just picked, shown right away while the back camera switches.
    var pendingLens: BackLens?
    var displayLens: BackLens? { pendingLens ?? plan?.backLens }
    var plan: DualPlan?
    var codec: VideoCodec = Preferences.load(.codec) ?? .hevc
    var save: SaveOption = Preferences.load(.save) ?? .all
    var heatPolicy: HeatPolicy = Preferences.load(.heat) ?? .smart
    var layout: DualLayout = Preferences.load(.layout) ?? DualLayout()
    var zoomStops: [ZoomStop] = []
    var displayZoom: CGFloat = 1
    var hasTorch = false
    var torchOn = false
    var isRecording = false
    var recordingStart: Date?
    var frontStopped = false
    /// A lens-pair switch is under way (the back picture pauses for a moment).
    var switchingLens = false
    var pressure: PressureLevel = .nominal
    /// A short message in the yellow pill.
    var notice: String?
    var interruptionMessage: String?
    var lastThumbnail: UIImage?
    /// Takes waiting to be combined and saved.
    var processing = 0
    var forcePrompt: ForcePrompt?
    var micDenied = false
    /// Another app holds the microphone (a call, a voice recorder): the cameras run without sound.
    var micBusy = false
    /// The yellow square after tap to focus.
    var focusMark: FocusMark?
    var isDemo = false

    // MARK: Photo mode
    var captureMode: CaptureMode = Preferences.load(.captureMode) ?? .video
    var photoFormat: PhotoFormat = Preferences.load(.photoFormat) ?? .heif
    /// The back camera's flash for photos.
    var flashOn = false
    /// Self-timer for photos: 0, 3 or 10 seconds.
    var timerSeconds: Int = Preferences.load(.timer) ?? 0
    /// Seconds left on the self-timer, shown big over the picture.
    var countdown: Int?
    var takingPhoto = false
    /// Bumped on every photo, for the native camera's quick black blink.
    var photoID = 0
    /// The photo size each camera takes, in megapixels, measured from the cameras.
    var photoMegapixels: (back: Double, front: Double) = (0, 0)

    // MARK: Top row
    /// The controls in the top row beside the Dynamic Island, per mode (iOS 27's "Essentials").
    var videoEssentials: [CameraControl] = Preferences.load(.videoEssentials) ?? CameraControl.defaultEssentials(.video)
    var photoEssentials: [CameraControl] = Preferences.load(.photoEssentials) ?? CameraControl.defaultEssentials(.photo)

    var essentials: [CameraControl] {
        get { captureMode == .video ? videoEssentials : photoEssentials }
        set {
            if captureMode == .video {
                videoEssentials = newValue
                Preferences.store(newValue, .videoEssentials)
            } else {
                photoEssentials = newValue
                Preferences.store(newValue, .photoEssentials)
            }
        }
    }

    /// Every control the current mode offers on this iPhone, in the order the sheet shows them.
    var availableControls: [CameraControl] {
        CameraControl.allCases.filter { control in
            guard control.modes.contains(captureMode) else { return false }
            switch control {
            case .torch, .flash: return hasTorch || isDemo
            case .lenses: return lensChoices.count > 1
            default: return true
            }
        }
    }

    let orientation = DeviceOrientation()
    /// The two live pictures. Created up front because the capture graph feeds their layers.
    @ObservationIgnored let previewContainer = DualPreviewContainer()

    /// On iPhones that can't run every back lens next to the front camera: the pairs to choose from.
    var lensChoices: [BackLens] { capabilities?.lensChoices(for: mode) ?? [] }

    /// Looked up once: asking AVFoundation for cameras is slow, and the Format panel redraws often.
    func zoomRange(of lens: BackLens) -> String {
        zoomRanges[lens] ?? lens.fallbackZoomRange
    }

    // MARK: Capture
    @ObservationIgnored private var graph: CaptureGraph?
    /// The back camera's zoom range, read on the session queue after each camera change.
    @ObservationIgnored private var backZoom: BackZoom?
    @ObservationIgnored private var currentFPS = 30
    @ObservationIgnored private var heatTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var forcedModes: Set<VideoMode> = Preferences.load(.forcedModes) ?? []
    @ObservationIgnored private var preferredLens: BackLens? = Preferences.load(.lens)
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var zoomRanges: [BackLens: String] = [:]
    /// Zoom buttons of every lens pair, looked up once (by lens).
    @ObservationIgnored private var lensStops: [BackLens: [ZoomStop]] = [:]
    @ObservationIgnored private var selfTestStarted = false
    @ObservationIgnored private var applyingPending = false
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var lastMicRetry = Date.distantPast
    @ObservationIgnored private var micWatch: Task<Void, Never>?
    @ObservationIgnored private var resumedLeftovers = false

    // MARK: Recording
    /// Every take whose files are still open, by id. The live one is `liveTakeID`.
    @ObservationIgnored private var takes: [String: Take] = [:]
    @ObservationIgnored private var openFiles: [String: Set<String>] = [:]
    @ObservationIgnored private var recorders: [String: TakeRecorder] = [:]
    @ObservationIgnored private var liveTakeID: String?
    @ObservationIgnored private var pendingSwitch: (lens: BackLens, zoom: CGFloat?)?

    // MARK: Saving
    @ObservationIgnored private var saveQueue: [Take] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard !isDemo, !starting else { return }
        starting = true
        defer { starting = false }

        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            status = .denied
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        micDenied = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            status = .unsupported
            return
        }
        if graph == nil { await setUp() }
        guard let graph, status == .ready else { return }
        // Back in the foreground: take the microphone again (it may have been freed, or taken).
        await refreshMicrophone()
        graph.queue.async { graph.startRunning() }
        finishLeftovers()
        #if DEBUG
        Diagnostics.shared.attach(self)
        if ProcessInfo.processInfo.arguments.contains("-ClearLastTake") {
            try? FileManager.default.removeItem(at: URL.cachesDirectory.appendingPathComponent("LastTake"))
            log("cleared LastTake")
        }
        if ProcessInfo.processInfo.arguments.contains("-SelfTest"), !selfTestStarted {
            selfTestStarted = true
            runSelfTest()
        }
        if ProcessInfo.processInfo.arguments.contains("-RecordTest"), !selfTestStarted {
            selfTestStarted = true
            Task {
                log("record test: mic wiring \(CaptureGraph.micWiring.rawValue), sound \(!micBusy && !micDenied)")
                try? await Task.sleep(for: .seconds(2))
                startRecording(test: true)
                try? await Task.sleep(for: .seconds(3))
                stopRecording()
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if openFiles.isEmpty, takes.isEmpty, saveTask == nil, saveQueue.isEmpty { break }
                }
                log("record test done")
            }
        }
        #endif
    }

    func stop() {
        if isRecording { stopRecording() }
        guard let graph else { return }
        graph.queue.async {
            graph.stopRunning()
            AudioSetup.deactivate()
        }
    }

    private func setUp() async {
        let graph = CaptureGraph(backPreview: previewContainer.back.previewLayer,
                                 frontPreview: previewContainer.front.previewLayer)
        self.graph = graph
        observe(graph.session)
        graph.onPressureChange = { [weak self] level in
            Task { @MainActor in self?.pressureChanged(PressureLevel(level)) }
        }

        let capabilities = await loadCapabilities(graph)
        self.capabilities = capabilities
        guard !capabilities.plans.isEmpty else {
            status = .unsupported
            return
        }
        let modes = capabilities.modes
        if !modes.contains(mode) { mode = modes.contains(.standard) ? .standard : modes[0] }
        // Lens pairs and their zoom buttons, looked up once and off the main thread.
        let lenses = Set(capabilities.plans.map(\.backLens))
        let lookup: [(BackLens, String, [ZoomStop])] = await graph.perform {
            lenses.compactMap { lens in
                guard let device = CaptureGraph.backCamera(lens) else { return nil }
                return (lens, CaptureGraph.zoomRange(of: lens), CaptureGraph.zoomStops(for: device, lens: lens))
            }
        }
        for (lens, range, stops) in lookup {
            zoomRanges[lens] = range
            lensStops[lens] = stops
        }
        if !micDenied {
            let refusal = await graph.perform { AudioSetup.activate() }
            micBusy = refusal != nil
            if let refusal { microphoneTaken(refusal) }
        }
        await apply(mode)
        status = .ready
    }

    /// What this iPhone can do: measured once, then remembered for this model and iOS version.
    private func loadCapabilities(_ graph: CaptureGraph) async -> DualCapabilities {
        let key = Self.deviceKey
        if let cached: DualCapabilities = Preferences.load(.capabilities), cached.key == key, !cached.plans.isEmpty {
            return cached
        }
        status = .measuring
        let plans = await graph.perform { graph.probe() }
        let capabilities = DualCapabilities(key: key, plans: plans)
        Preferences.store(capabilities, .capabilities)
        return capabilities
    }

    /// The iPhone model, iOS version and probe version.
    static var deviceKey: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine)|\(UIDevice.current.systemVersion)|1"
    }

    /// Switches both cameras to `mode`, keeping the chosen lens pair if it can. Only what differs
    /// changes: a frame rate is instant; a resolution or lens change blurs the picture briefly.
    func apply(_ mode: VideoMode) async {
        if captureMode == .photo {
            await applyPhoto()
            return
        }
        guard let graph, let capabilities, var plan = capabilities.plan(for: mode, lens: preferredLens),
              !isRecording else { return }
        let options = RecordingOptions(codec: codec, audio: !micDenied && !micBusy,
                                       ceilingFPS: capabilities.ceilingFPS(height: mode.height, lens: plan.backLens))
        let planned = plan
        let previous = self.plan
        let disruptive = previous.map { $0.mode.height != mode.height || $0.backLens != plan.backLens } ?? false
        if disruptive { setPreviewsBlurred(true) }
        let started = CACurrentMediaTime()
        let result: Result<SessionCosts, Error> = await graph.perform {
            Result { try graph.update(to: planned, options: options) }
        }
        log("apply \(mode.label) took \(Int((CACurrentMediaTime() - started) * 1000)) ms\(disruptive ? " (blurred)" : "")")
        if disruptive {
            // Let the new frames arrive before the blur lifts.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                setPreviewsBlurred(false)
            }
        }
        switch result {
        case .success(let costs):
            plan.hardwareCost = costs.hardware
            plan.pressureCost = costs.pressure
            self.plan = plan
            self.mode = mode
            currentFPS = mode.fps
            Preferences.store(mode, .mode)
        case .failure(let error):
            notice = "Couldn't switch to \(mode.label)"
            log("configure \(mode.label) failed: \(error)")
        }
        await cameraChanged()
    }

    private func setPreviewsBlurred(_ blurred: Bool, backOnly: Bool = false) {
        previewContainer.back.setBlurred(blurred)
        if !backOnly { previewContainer.front.setBlurred(blurred) }
    }

    /// After the cameras change: the zoom buttons and the torch follow. What they need is read
    /// on the session queue; the screen never waits on a camera.
    private func cameraChanged() async {
        guard let graph else { return }
        let info = await graph.perform { graph.info() }
        backZoom = info.zoom
        hasTorch = info.hasTorch
        if torchOn {
            if hasTorch { graph.queue.async { graph.setTorch(true) } } else { torchOn = false }
        }
        setUpZoomStops()
    }

    /// Picks a size or frame rate. The choice shows at once; the cameras follow, and if several
    /// taps come in while they switch, they go straight to the last one.
    func select(_ mode: VideoMode) {
        guard mode != displayMode, !isRecording else { return }
        pendingMode = mode
        guard !applyingPending else { return }
        applyingPending = true
        Task {
            while let target = pendingMode {
                if target != self.mode { await apply(target) }
                // Done, unless something newer was picked meanwhile. If the switch failed, the
                // controls fall back to what's really running.
                if pendingMode == target { pendingMode = nil }
            }
            applyingPending = false
        }
    }

    /// The mic-off button: why there's no sound.
    func explainMicrophone() {
        notice = micDenied
            ? "Microphone access is off in Settings, so videos have no sound"
            : "Another app is using the microphone (a call or voice chat on your headphones). Sound comes back when it ends"
    }

    func select(_ codec: VideoCodec) {
        guard !isRecording else { return }
        self.codec = codec
        Preferences.store(codec, .codec)
        Task { await apply(mode) }
    }

    func select(_ save: SaveOption) {
        self.save = save
        Preferences.store(save, .save)
    }

    func select(_ policy: HeatPolicy) {
        heatPolicy = policy
        Preferences.store(policy, .heat)
    }

    func toggleTorch() {
        guard let graph, hasTorch else { return }
        torchOn.toggle()
        let on = torchOn
        graph.queue.async { graph.setTorch(on) }
    }

    /// Recovers from the things that stop a camera: calls, other apps, media server resets.
    private func observe(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                self?.log("interrupted: \(String(describing: reason?.rawValue))")
                switch reason {
                case .videoDeviceNotAvailableDueToSystemPressure:
                    self?.interruptionMessage = "Cameras paused to cool down"
                case .audioDeviceInUseByAnotherClient:
                    self?.interruptionMessage = "Microphone in use by another app"
                default:
                    self?.interruptionMessage = "Camera in use by another app"
                }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interruptionMessage = nil
                self?.log("interruption ended")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.sessionFailed(note.userInfo?[AVCaptureSessionErrorKey] as? NSError)
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runningSince = Date()
                self?.log("session running")
            }
        })
        // A call ending (or headphones changing) can free the microphone again.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryMicrophone() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let graph = self.graph else { return }
                self.focusMark = nil
                graph.queue.async { graph.resumeContinuousFocus() }
            }
        })
    }

    /// The session stopped or couldn't start. If iOS refused the microphone because another app
    /// outranks this one (a phone or FaceTime call, a voice chat), the cameras carry on without
    /// sound rather than not at all. Anything else: try again a few times, backing off.
    private func sessionFailed(_ error: NSError?) {
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        log("runtime error \(error?.code ?? 0) / \(underlying?.code ?? 0)")
        #if DEBUG
        Diagnostics.shared.logAudioSession()
        #endif
        guard let graph else { return }
        // Only a session that ran for a while counts as recovered.
        if let runningSince, Date().timeIntervalSince(runningSince) > 5 { restartAttempts = 0 }
        runningSince = nil

        // '!pri': the audio session can't be activated, another app has priority.
        if underlying?.code == 561_017_449, !micBusy {
            micBusy = true
            microphoneTaken()
            Task {
                // A recording cut off by this closes its files first.
                for _ in 0..<25 where isRecording { try? await Task.sleep(for: .milliseconds(200)) }
                await apply(mode)
                graph.queue.async { graph.startRunning() }
            }
            return
        }
        restartAttempts += 1
        guard restartAttempts <= 4 else {
            log("giving up restarting")
            return
        }
        let delay = 0.4 * Double(restartAttempts)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            graph.queue.async { graph.startRunning() }
        }
    }

    private func microphoneTaken(_ reason: String? = nil) {
        lastMicRetry = Date()
        notice = "Microphone in use by another app, recording without sound"
        log("microphone refused (\(reason ?? "session")): \(AudioSetup.summary)")
        watchForMicrophone()
    }

    /// Takes the microphone if iOS allows it, and switches the cameras' sound on or off to match.
    private func refreshMicrophone() async {
        guard let graph, !micDenied, !isRecording else { return }
        let refusal = await graph.perform { AudioSetup.activate() }
        let available = refusal == nil
        guard available == micBusy else { return }
        micBusy = !available
        if let refusal {
            microphoneTaken(refusal)
        } else {
            micWatch?.cancel()
            notice = "Microphone is back"
            log("microphone back")
        }
        await apply(mode)
    }

    /// While another app has the microphone, ask again every few seconds and on audio route changes.
    private func retryMicrophone() {
        guard micBusy, !isRecording, status == .ready, Date().timeIntervalSince(lastMicRetry) > 4, let graph else { return }
        lastMicRetry = Date()
        Task {
            await refreshMicrophone()
            graph.queue.async { graph.startRunning() }
        }
    }

    private func watchForMicrophone() {
        micWatch?.cancel()
        micWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.micBusy else { return }
                self.retryMicrophone()
            }
        }
    }

    // MARK: - Zoom and lenses

    /// The zoom buttons cover every lens pair: on an iPhone 14 Pro that's .5 (ultra wide pair)
    /// and 3 (telephoto pair) next to 1 and 2. Picking one from the other pair switches pairs.
    private func setUpZoomStops() {
        guard let zoom = backZoom, let current = plan?.backLens else {
            zoomStops = []
            return
        }
        var stops = zoom.stops
        for lens in lensChoices where lens != current {
            for stop in lensStops[lens] ?? [] where !stops.contains(where: { abs($0.display - stop.display) < 0.05 }) {
                stops.append(stop)
            }
        }
        zoomStops = stops.sorted { $0.display < $1.display }
        if displayZoom < zoom.minFactor * zoom.multiplier - 0.01 { displayZoom = 1 }
        applyZoom(animated: false)
    }

    func selectZoom(_ stop: ZoomStop) {
        if let lens = stop.lens, lens != plan?.backLens {
            selectLens(lens, zoom: stop.display)
            return
        }
        displayZoom = stop.display
        applyZoom(animated: true)
    }

    /// Pinch zoom on the back camera, in display units, within the current lens pair.
    func setDisplayZoom(_ value: CGFloat) {
        guard let zoom = backZoom, !switchingLens else { return }
        let m = zoom.multiplier
        let lowest = zoom.minFactor * m
        let highest = min(zoom.maxFactor, 15 / m) * m
        displayZoom = min(max(value, lowest), highest)
        applyZoom(animated: false)
    }

    private func applyZoom(animated: Bool) {
        guard let graph, let zoom = backZoom else { return }
        let factor = displayZoom / zoom.multiplier
        graph.queue.async { graph.setZoom(factor, animated: animated) }
    }

    /// Switches the back camera to another lens pair. While recording, the back file closes,
    /// the camera switches and a new back file starts (the front keeps recording); the pieces
    /// are joined into one back video when the take is saved.
    func selectLens(_ lens: BackLens, zoom: CGFloat? = nil) {
        guard let graph, lens != plan?.backLens, !switchingLens, lensChoices.contains(lens) else { return }
        preferredLens = lens
        pendingLens = lens
        Preferences.store(lens, .lens)
        if isRecording {
            // Swapping the back camera makes iOS close every recording file, the front's too.
            // So close both cleanly, switch, and start both again: the two stay in step.
            pendingSwitch = (lens, zoom)
            switchingLens = true
            graph.queue.async { graph.stopRecording() }
            if let id = liveTakeID { giveUpOnStuckFiles(id, after: 4) }
            return
        }
        guard openFiles.values.allSatisfy(\.isEmpty) else {
            pendingLens = nil
            return
        }
        switchingLens = true
        Task { await switchBack(to: lens, zoom: zoom) }
    }

    @discardableResult
    private func switchBack(to lens: BackLens, zoom: CGFloat?) async -> Bool {
        guard let graph, let capabilities, let previous = plan,
              var next = capabilities.plan(for: mode, lens: lens) else {
            switchingLens = false
            pendingLens = nil
            return false
        }
        switchingLens = true
        setPreviewsBlurred(true, backOnly: true)
        defer {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                setPreviewsBlurred(false, backOnly: true)
            }
        }
        let codec = codec
        let planned = next
        let result: Result<SessionCosts, Error> = await graph.perform {
            Result { try graph.switchBack(to: planned, codec: codec) }
        }
        var switched = false
        switch result {
        case .success(let costs):
            next.hardwareCost = costs.hardware
            next.pressureCost = costs.pressure
            plan = next
            switched = true
        case .failure(let error):
            log("lens switch failed: \(error)")
            _ = await graph.perform { try? graph.switchBack(to: previous, codec: codec) }
            notice = "Couldn't switch lenses"
        }
        await cameraChanged()
        if switched, let zoom {
            displayZoom = zoom
            applyZoom(animated: false)
        }
        switchingLens = false
        pendingLens = nil
        return switched
    }

    /// Tap to focus. `point` is normalized in the tapped picture, with a top-left origin.
    func focus(at point: CGPoint, onBack: Bool) {
        focusMark = FocusMark(point: point, onBack: onBack, id: (focusMark?.id ?? 0) + 1)
        guard let graph else { return }
        let layer = onBack ? graph.backPreview : graph.frontPreview
        let devicePoint = layer.captureDevicePointConverted(
            fromLayerPoint: CGPoint(x: point.x * layer.bounds.width, y: point.y * layer.bounds.height))
        graph.queue.async { graph.focus(at: devicePoint, onBack: onBack) }
    }

    // MARK: - Layout

    func setLayout(_ new: DualLayout) {
        layout = new
        Preferences.store(new, .layout)
        if isRecording, let id = liveTakeID {
            takes[id]?.timeline.append(new, at: CACurrentMediaTime())
        }
    }

    func swapCameras() {
        var new = layout
        new.backIsMain.toggle()
        setLayout(new)
    }

    func setStyle(_ style: DualStyle) {
        var new = layout
        new.style = style
        setLayout(new)
    }

    func movePiP(to corner: PiPCorner) {
        var new = layout
        new.corner = corner
        setLayout(new)
    }

    // MARK: - Recording

    func recordPressed() {
        if captureMode == .photo {
            takePhoto()
            return
        }
        if isRecording {
            stopRecording()
            return
        }
        // The last take's files close within a moment; wait for them before starting another.
        guard status == .ready, !switchingLens, openFiles.values.allSatisfy(\.isEmpty), let plan else { return }
        if let free = Self.freeSpace, free < 1_000_000_000 {
            notice = "Not enough free space to record"
            return
        }
        let hot = pressure >= .serious
            || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if heatPolicy == .smart, !plan.isSustainable || hot, !forcedModes.contains(mode) || hot {
            forcePrompt = ForcePrompt(mode: mode,
                                      alternative: plan.isSustainable ? nil : capabilities?.recommendedAlternative(to: mode),
                                      alreadyHot: plan.isSustainable)
            return
        }
        startRecording()
    }

    /// From the heat prompt: record what was chosen anyway.
    func recordAnyway(remember: Bool) {
        if remember, let mode = forcePrompt?.mode {
            forcedModes.insert(mode)
            Preferences.store(forcedModes, .forcedModes)
        }
        forcePrompt = nil
        startRecording()
    }

    /// From the heat prompt: switch to the mode that runs cool, then record.
    func recordRecommended() {
        guard let alternative = forcePrompt?.alternative else { return }
        forcePrompt = nil
        Task {
            await apply(alternative)
            startRecording()
        }
    }

    private func startRecording(test: Bool = false) {
        guard let graph, let plan, !isRecording else { return }
        // Saving the last take waits: the cameras get the GPU, encoders and disk.
        saveTask?.cancel()

        var take = Take(mode: mode, codec: codec, save: save,
                        orientation: RecordOrientation(orientation.last), layout: layout)
        do {
            try take.createFolder()
        } catch {
            notice = "Couldn't start recording"
            return
        }
        let backURL = take.addSegment(.back, lens: plan.backLens)
        let frontURL = take.addSegment(.front, lens: nil)
        if micDenied { take.notes.append("Recorded without sound: microphone access is off") }
        if micBusy { take.notes.append("Recorded without sound: another app had the microphone") }
        if test { take.isTest = true }
        take.write()
        let id = take.id
        takes[id] = take
        openFiles[id] = [backURL.lastPathComponent, frontURL.lastPathComponent]
        liveTakeID = id

        // The preview may have slowed down to cool off; recordings start at full speed.
        if currentFPS != mode.fps {
            let fps = mode.fps
            graph.queue.async { graph.setFrameRate(fps) }
            currentFPS = fps
        }

        let recorder = TakeRecorder()
        recorder.onStart = { [weak self] url, clock in
            Task { @MainActor in
                self?.takes[id]?.started(url, clock: clock)
                self?.log("started \(url.lastPathComponent)")
            }
        }
        recorder.onFinish = { [weak self] url, ok in
            Task { @MainActor in self?.fileFinished(url, ok: ok, take: id) }
        }
        recorders[id] = recorder

        Task {
            let angles = await graph.perform { graph.startRecording(back: backURL, front: frontURL, delegate: recorder) }
            log("recording \(id) \(mode.label) back \(angles.back)° front \(angles.front)°")
        }
        isRecording = true
        recordingStart = Date()
        frontStopped = false
        UIApplication.shared.isIdleTimerDisabled = true
        startHeatTimer()
        watchForFilesThatDontStart(id)
    }

    /// A camera file that hasn't started a few seconds in isn't going to: record without it,
    /// rather than keep a file open that would never close.
    private func watchForFilesThatDontStart(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.liveTakeID == id, self.isRecording, let take = self.takes[id], let graph = self.graph else { return }
            let stuck = take.segments.filter { $0.clock == nil && self.openFiles[id]?.contains($0.file) == true }
            guard !stuck.isEmpty else { return }
            for segment in stuck {
                self.log("\(segment.file) didn't start; recording without it")
                self.openFiles[id]?.remove(segment.file)
            }
            if stuck.contains(where: { $0.camera == .back }) {
                self.notice = "The back camera couldn't start recording"
                self.stopRecording()
            } else {
                self.frontStopped = true
                graph.queue.async { graph.stopFront() }
                self.notice = "The front camera couldn't start recording"
            }
        }
    }

    /// iOS occasionally never finishes a file. Once nothing should still be writing (the take was
    /// stopped, or a lens switch is waiting), give it a few seconds, then carry on without it, so
    /// the rest of the take still saves and the record button never stays blocked.
    private func giveUpOnStuckFiles(_ id: String, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let stuck = self.openFiles[id], !stuck.isEmpty, self.takes[id] != nil,
                  id != self.liveTakeID || self.pendingSwitch != nil else { return }
            self.log("gave up waiting for \(stuck.sorted())")
            self.openFiles[id] = []
            if id == self.liveTakeID, let pending = self.pendingSwitch {
                self.pendingSwitch = nil
                await self.continueAfterSwitch(to: pending.lens, zoom: pending.zoom, take: id)
            } else {
                self.finalize(id)
            }
        }
    }

    func stopRecording() {
        guard let graph, isRecording else { return }
        let id = liveTakeID
        graph.queue.async { graph.stopRecording() }
        endRecording()
        if let id { giveUpOnStuckFiles(id, after: 4) }
    }

    private func endRecording() {
        isRecording = false
        recordingStart = nil
        liveTakeID = nil
        pendingSwitch = nil
        pendingLens = nil
        frontStopped = false
        heatTimer?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        if let graph { graph.queue.async { graph.takeEnded() } }
        if currentFPS != mode.fps, pressure <= .fair, let graph {
            let fps = mode.fps
            graph.queue.async { graph.setFrameRate(fps) }
            currentFPS = fps
        }
    }

    private func fileFinished(_ url: URL, ok: Bool, take id: String) {
        guard takes[id] != nil else { return }
        openFiles[id]?.remove(url.lastPathComponent)
        log("closed \(url.lastPathComponent) ok=\(ok)")

        // Closed for a lens switch: once every file is closed, switch and carry on with new files.
        if id == liveTakeID, let pending = pendingSwitch {
            if openFiles[id]?.isEmpty ?? true {
                pendingSwitch = nil
                Task { await continueAfterSwitch(to: pending.lens, zoom: pending.zoom, take: id) }
            }
            return
        }
        guard openFiles[id]?.isEmpty ?? true else { return }
        // Everything is closed: either the stop button, or iOS stopped the cameras.
        if id == liveTakeID { endRecording() }
        finalize(id)
    }

    private func continueAfterSwitch(to lens: BackLens, zoom: CGFloat?, take id: String) async {
        let switched = await switchBack(to: lens, zoom: zoom)
        guard isRecording, id == liveTakeID, let graph, let recorder = recorders[id], var take = takes[id] else {
            if openFiles[id]?.isEmpty ?? true { finalize(id) }
            return
        }
        // Keep recording, on the new lens pair (or the old one if that failed). The front starts
        // a new file too, unless it was stopped to cool down.
        let backURL = take.addSegment(.back, lens: plan?.backLens)
        let frontURL: URL? = frontStopped ? nil : take.addSegment(.front, lens: nil)
        take.notes.append(switched ? "Switched to \(zoomRange(of: lens))" : "Lens switch failed")
        take.write()
        takes[id] = take
        openFiles[id, default: []].insert(backURL.lastPathComponent)
        if let frontURL { openFiles[id, default: []].insert(frontURL.lastPathComponent) }
        graph.queue.async { graph.resume(back: backURL, front: frontURL, delegate: recorder) }
    }

    private func finalize(_ id: String) {
        guard var take = takes.removeValue(forKey: id) else { return }
        openFiles[id] = nil
        recorders[id] = nil
        take.settleTimes()
        take.write()
        enqueueSave(take)
        // A lens picked just as recording stopped takes effect now.
        if !isRecording, let lens = preferredLens, lens != plan?.backLens, lensChoices.contains(lens) {
            Task { await switchBack(to: lens, zoom: nil) }
        }
    }

    // MARK: - Saving

    /// Takes are combined and saved one at a time, only while nothing is recording.
    private func enqueueSave(_ take: Take) {
        saveQueue.append(take)
        runSaves()
    }

    private func runSaves() {
        processing = saveQueue.count + (saveTask == nil ? 0 : 1)
        guard saveTask == nil, !isRecording, !saveQueue.isEmpty else { return }
        let take = saveQueue.removeFirst()
        // If the app goes to the background mid-save, iOS gives it a little time; when that runs
        // out the save is postponed to the next launch rather than killed half-way.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Saving \(take.id)") { [weak self] in
            MainActor.assumeIsolated { self?.saveTask?.cancel() }
        }
        saveTask = Task { [weak self] in
            let outcome = await TakeSaver.finish(take)
            guard let self else { return }
            if outcome.postponed {
                self.saveQueue.insert(take, at: 0)
                self.log("save postponed \(take.id)")
            } else {
                if let thumbnail = outcome.thumbnail { self.lastThumbnail = thumbnail }
                if let message = outcome.message { self.notice = message }
                self.log("saved \(take.id)")
            }
            self.saveTask = nil
            UIApplication.shared.endBackgroundTask(background)
            if !self.isRecording { self.runSaves() } else { self.processing = self.saveQueue.count }
        }
        processing = saveQueue.count + 1
    }

    /// Recordings cut off by a crash or a force-quit, or postponed: the files are playable up to
    /// the last few seconds, so finish saving them.
    private func finishLeftovers() {
        guard !resumedLeftovers else { return }
        resumedLeftovers = true
        for var take in Take.leftovers() {
            if take.segments.contains(where: { $0.start == nil }) { take.settleTimes() }
            enqueueSave(take)
        }
    }

    private static var freeSpace: Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Roughly how many minutes fit on the iPhone with the current settings.
    var minutesLeft: Int? {
        guard let free = Self.freeSpace, let plan else { return nil }
        var perMinute = StorageEstimate.megabytesPerMinute(height: plan.mode.height, fps: plan.mode.fps, codec: codec)
            + StorageEstimate.megabytesPerMinute(height: plan.frontHeight, fps: plan.mode.fps, codec: codec)
        if save != .angles {
            perMinute += StorageEstimate.megabytesPerMinute(height: plan.mode.height, fps: plan.mode.fps, codec: codec)
        }
        return Int(Double(free) / 1_000_000 / perMinute)
    }

    // MARK: - Heat

    private func pressureChanged(_ level: PressureLevel) {
        if level != pressure { log("pressure \(level)") }
        pressure = level
        applyHeatActions()
    }

    /// While recording and hot, check again every so often: each check can step down one more notch.
    private func startHeatTimer() {
        heatTimer?.cancel()
        heatTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                if self.isRecording, self.pressure >= .serious { self.applyHeatActions() }
            }
        }
    }

    private func applyHeatActions() {
        guard let graph else { return }
        let guardian = HeatGuard(policy: heatPolicy)
        let actions = guardian.actions(level: pressure, recording: isRecording, fps: currentFPS,
                                       modeFPS: mode.fps, frontRunning: isRecording && !frontStopped)
        for action in actions {
            switch action {
            case .setFrameRate(let fps):
                currentFPS = fps
                graph.queue.async { graph.setFrameRate(fps) }
                if isRecording {
                    let text = "Slowed to \(fps) fps to cool down"
                    notice = text
                    if let id = liveTakeID { takes[id]?.notes.append(text) }
                }
            case .stopFront:
                frontStopped = true
                graph.queue.async { graph.stopFront() }
                notice = "Front camera stopped to cool down"
                if let id = liveTakeID { takes[id]?.notes.append("Front camera stopped to cool down") }
            case .warn(let text):
                notice = text
            }
        }
    }

    // MARK: - Photo mode

    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, !isRecording, !takingPhoto else { return }
        captureMode = mode
        Preferences.store(mode, .captureMode)
        if torchOn, mode == .photo { toggleTorch() }
        guard !isDemo else { return }
        Task { await apply(self.mode) }
    }

    func select(_ format: PhotoFormat) {
        photoFormat = format
        Preferences.store(format, .photoFormat)
    }

    func selectTimer(_ seconds: Int) {
        timerSeconds = seconds
        Preferences.store(seconds, .timer)
    }

    /// Photo mode: 4:3 formats with the largest photos two cameras allow. Some lens pairs may not
    /// fit the camera budget with photos, so it falls back to the others.
    private func applyPhoto() async {
        guard let graph, let capabilities, !isRecording else { return }
        let firstChoice = preferredLens ?? plan?.backLens
        let lenses = ([firstChoice].compactMap { $0 } + BackLens.allCases).reduce(into: [BackLens]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        setPreviewsBlurred(true)
        defer {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                setPreviewsBlurred(false)
            }
        }
        let options = RecordingOptions(codec: codec, audio: false, photo: true)
        for lens in lenses {
            guard var next = capabilities.plan(for: .standard, lens: lens), next.backLens == lens else { continue }
            let planned = next
            let result: Result<SessionCosts, Error> = await graph.perform {
                Result { try graph.update(to: planned, options: options) }
            }
            guard case .success(let costs) = result, costs.hardware <= 1 else {
                log("photo mode with \(lens.rawValue) doesn't fit")
                continue
            }
            next.hardwareCost = costs.hardware
            next.pressureCost = costs.pressure
            plan = next
            photoMegapixels = await graph.perform { graph.photoMegapixels() }
            log("photo mode \(lens.rawValue): \(String(format: "%.1f", photoMegapixels.back)) + \(String(format: "%.1f", photoMegapixels.front)) MP")
            await cameraChanged()
            return
        }
        notice = "Photo mode isn't available on this iPhone"
        captureMode = .video
        await apply(mode)
    }

    /// Takes a photo with both cameras at once (after the self-timer, if set) and saves it.
    func takePhoto() {
        guard status == .ready, !takingPhoto, !switchingLens, countdown == nil else {
            if countdown != nil { countdown = nil }   // Tapping during the countdown cancels it.
            return
        }
        Task {
            if timerSeconds > 0 {
                for left in stride(from: timerSeconds, to: 0, by: -1) {
                    countdown = left
                    try? await Task.sleep(for: .seconds(1))
                    if countdown == nil { return }
                }
                countdown = nil
            }
            capturePhoto()
        }
    }

    private func capturePhoto() {
        guard let graph, !isDemo else {
            photoID += 1
            return
        }
        takingPhoto = true
        photoID += 1
        let format = photoFormat, flash = flashOn, layout = layout, save = save
        let orientation = RecordOrientation(orientation.last)
        graph.queue.async {
            graph.capturePhotos(format: format, flash: flash) { photo in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.takingPhoto = false
                    self.log("photo: back \(photo.back?.count ?? 0) bytes, front \(photo.front?.count ?? 0) bytes")
                    self.processing += 1
                    let outcome = await PhotoSaver.save(photo, layout: layout, orientation: orientation, format: format, save: save)
                    self.processing -= 1
                    if let thumbnail = outcome.thumbnail { self.lastThumbnail = thumbnail }
                    if let message = outcome.message { self.notice = message }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private func log(_ text: String) {
        #if DEBUG
        Diagnostics.shared.log(text)
        #endif
    }

    #if DEBUG
    /// Launched with -SelfTest: steps through frame rates, resolutions and lens pairs the way a
    /// person tapping the top bar and zoom buttons would, so the report shows how each change behaves.
    private func runSelfTest() {
        Task {
            log("self-test start")
            try? await Task.sleep(for: .seconds(2))
            // Three quick taps, like a person changing their mind: the controls must show each
            // choice at once, and the cameras must end on the last one.
            let tapped = CACurrentMediaTime()
            for fps in [60, 24, 30] {
                select(VideoMode(height: 1080, fps: fps))
                log("tapped \(fps): shows \(displayMode.label)")
                try? await Task.sleep(for: .milliseconds(120))
            }
            while applyingPending { try? await Task.sleep(for: .milliseconds(10)) }
            log("three quick taps settled on \(mode.label) in \(Int((CACurrentMediaTime() - tapped) * 1000)) ms")
            try? await Task.sleep(for: .seconds(1.5))
            for fps in [60, 24, 30] {
                await apply(VideoMode(height: 1080, fps: fps))
                try? await Task.sleep(for: .seconds(1.5))
            }
            if capabilities?.heights.contains(2160) == true {
                await apply(VideoMode(height: 2160, fps: 30))
                try? await Task.sleep(for: .seconds(1.5))
                await apply(VideoMode(height: 1080, fps: 30))
                try? await Task.sleep(for: .seconds(1.5))
            }
            for stop in zoomStops where stop.lens != plan?.backLens {
                let started = CACurrentMediaTime()
                selectZoom(stop)
                while switchingLens { try? await Task.sleep(for: .milliseconds(10)) }
                log("zoom \(stop.label) switched lenses in \(Int((CACurrentMediaTime() - started) * 1000)) ms, now \(plan?.backLens.rawValue ?? "?")")
                try? await Task.sleep(for: .seconds(1.5))
            }
            if let wide = zoomStops.first(where: { $0.display < 1 }) { selectZoom(wide) }
            while switchingLens { try? await Task.sleep(for: .milliseconds(20)) }

            // An 8-second recording, switching to the telephoto pair halfway through.
            // Kept out of Photos; the files land in Library/Caches/LastTake for checking.
            try? await Task.sleep(for: .seconds(1))
            log("test recording start, lens \(plan?.backLens.rawValue ?? "?")")
            startRecording(test: true)
            try? await Task.sleep(for: .seconds(4))
            if let tele = zoomStops.first(where: { $0.display >= 3 }) {
                let started = CACurrentMediaTime()
                selectZoom(tele)
                while switchingLens { try? await Task.sleep(for: .milliseconds(10)) }
                log("mid-take switch to \(plan?.backLens.rawValue ?? "?") took \(Int((CACurrentMediaTime() - started) * 1000)) ms")
            }
            try? await Task.sleep(for: .seconds(4))
            stopRecording()
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(100))
                if openFiles.isEmpty, takes.isEmpty, saveTask == nil, saveQueue.isEmpty { break }
            }
            log("test recording saved")
            log("self-test done; session running \(graph?.session.isRunning ?? false)")
        }
    }

    /// What the diagnostics report needs to know. Camera details are read on the session queue.
    func diagnosticsSnapshot() async -> [String: Any] {
        var info: [String: Any] = [
            "status": "\(status)", "mode": mode.label, "layout": "\(layout)", "recording": isRecording,
            "pressure": "\(pressure)", "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "processing": processing, "zoom": displayZoom, "zoomStops": zoomStops.map(\.label),
            "lensChoices": lensChoices.map(\.rawValue), "deviceOrientation": orientation.last.rawValue,
            "micBusy": micBusy, "micDenied": micDenied, "audio": AudioSetup.summary,
        ]
        if let plan {
            info["plan"] = ["lens": plan.backLens.rawValue, "frontHeight": plan.frontHeight,
                            "hardwareCost": plan.hardwareCost, "pressureCost": plan.pressureCost]
        }
        if let graph {
            let cameras = await graph.perform { graph.diagnostics() }
            info.merge(cameras) { _, new in new }
        }
        return info
    }
    #endif

    // MARK: - Demo

    /// Fills the screen with a staged scene for screenshots and the Simulator, which has no cameras.
    func enterDemo(_ scene: String) {
        isDemo = true
        captureMode = scene.hasPrefix("photo") ? .photo : .video
        photoMegapixels = (7.1, 7.1)
        status = .ready
        let modes = [VideoMode(height: 1080, fps: 30), VideoMode(height: 1080, fps: 60), VideoMode(height: 2160, fps: 30)]
        capabilities = DualCapabilities(key: "demo", plans: modes.flatMap { mode in
            [BackLens.dualWide, .dual].map {
                DualPlan(mode: mode, backLens: $0, frontHeight: mode.height,
                         hardwareCost: mode.height > 1080 ? 1 : 0.5, pressureCost: mode.height > 1080 ? 2.4 : 0.5)
            }
        })
        mode = .standard
        plan = capabilities?.plan(for: mode)
        zoomStops = [ZoomStop(display: 0.5, deviceFactor: 1, lens: .dualWide), ZoomStop(display: 1, deviceFactor: 2, lens: .dualWide),
                     ZoomStop(display: 2, deviceFactor: 4, lens: .dualWide), ZoomStop(display: 3, deviceFactor: 3, lens: .dual)]
        displayZoom = 1
        hasTorch = true

        func picture(_ kind: DemoFeed.Kind, _ size: CGSize) -> UIImage? {
            let renderer = ImageRenderer(content: DemoFeed(kind: kind).frame(width: size.width, height: size.height))
            renderer.scale = 2
            return renderer.uiImage
        }
        if let back = picture(.back, CGSize(width: 390, height: 693)) { previewContainer.back.showStill(back) }
        if let front = picture(.front, CGSize(width: 240, height: 320)) { previewContainer.front.showStill(front) }
        lastThumbnail = picture(.back, CGSize(width: 120, height: 213))

        switch scene {
        case "split":
            layout = DualLayout(style: .split, backIsMain: true, corner: .topLeading)
        case "recording":
            layout = DualLayout(style: .pip, backIsMain: true, corner: .topTrailing)
            isRecording = true
            recordingStart = Date().addingTimeInterval(-74)
            pressure = .fair
        case "hot":
            forcePrompt = ForcePrompt(mode: VideoMode(height: 2160, fps: 30), alternative: .standard, alreadyHot: false)
        default:
            layout = DualLayout()
        }
    }
}

enum StorageEstimate {
    /// Apple's published sizes (1080p30 HEVC ≈ 60 MB a minute, 4K30 ≈ 170 MB, 4K60 ≈ 400 MB);
    /// H.264 is about twice the size.
    static func megabytesPerMinute(height: Int, fps: Int, codec: VideoCodec) -> Double {
        let at30: Double = height >= 2160 ? 170 : height >= 1080 ? 60 : 40
        let rate: Double = fps > 30 ? (height >= 2160 ? 400 / 170 : 1.5) : Double(fps) / 30
        return at30 * rate * (codec == .h264 ? 2 : 1)
    }
}

/// Saved settings.
enum Preferences {
    enum Key: String {
        case mode, codec, save, heat, layout, lens, forcedModes, capabilities
        case captureMode, photoFormat, timer, videoEssentials, photoEssentials
    }

    static func load<T: Decodable>(_ key: Key) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func store<T: Encodable>(_ value: T, _ key: Key) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}

/// Tracks how the phone is held, so icons turn while the portrait layout stays put,
/// and recordings know which way is up.
@MainActor
@Observable
final class DeviceOrientation {
    var iconAngle: Angle = .zero
    /// The last upright orientation (lying flat keeps the previous one).
    var last: UIDeviceOrientation = .portrait
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let current = UIDevice.current.orientation
        switch current {
        case .landscapeLeft: iconAngle = .degrees(90)
        case .landscapeRight: iconAngle = .degrees(-90)
        case .portrait: iconAngle = .zero
        default: break
        }
        if current.isPortrait || current.isLandscape { last = current }
    }
}

extension RecordOrientation {
    init(_ device: UIDeviceOrientation) {
        switch device {
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .portraitUpsideDown: self = .upsideDown
        default: self = .portrait
        }
    }
}
