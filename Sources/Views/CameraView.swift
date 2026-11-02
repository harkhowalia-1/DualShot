import AVFoundation
import SwiftUI

/// The native camera (iOS 27), with both cameras: the picture starts right under the Dynamic
/// Island with your chosen controls in the corners beside it; zoom, the shutter and the six-dot
/// tools button at its bottom; thumbnail, VIDEO | PHOTO and swap below.
struct CameraView: View {
    @State private var camera = DualCamera()
    /// The six-dot sheet, iOS 27 style.
    @State private var sheet: SheetState? = Self.demoSheet
    /// The top row while it's being edited.
    @State private var draft: [CameraControl] = []
    /// The native camera's quick black blink when a photo is taken.
    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinchBase: CGFloat?
    /// How tall the zoom and shutter controls inside the picture are, so the small window stays clear.
    @State private var pictureControlsHeight: CGFloat = 160
    @Environment(\.scenePhase) private var scenePhase

    private var iconAngle: Angle { camera.orientation.iconAngle }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .denied:
                MessageView(symbol: "camera.fill", title: "Camera Access Needed",
                            message: "Allow DualShot to use the camera in Settings.", showsSettings: true)
            case .unsupported:
                MessageView(symbol: "camera.on.rectangle", title: "Two Cameras Aren't Available",
                            message: unsupportedMessage, showsSettings: false)
            case .starting, .measuring, .ready:
                content
                    .overlay {
                        if camera.status == .measuring {
                            MessageView(symbol: "camera.aperture", title: "Getting Your Cameras Ready",
                                        message: "Checking what this iPhone can record. This only happens once.",
                                        showsSettings: false, busy: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black)
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let scene = DemoMode.scene {
                camera.enterDemo(scene)
                if sheet == .edit { draft = shownEssentials }
                return
            }
            await camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await camera.start() }
            } else if phase == .background {
                camera.stop()
            }
        }
        .overlay {
            if let prompt = camera.forcePrompt {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { camera.forcePrompt = nil }
                    HeatPrompt(prompt: prompt,
                               recommended: { camera.recordRecommended() },
                               anyway: { camera.recordAnyway(remember: $0) },
                               cancel: { camera.forcePrompt = nil })
                        .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: camera.forcePrompt)
    }

    private static var demoSheet: SheetState? {
        guard let scene = DemoMode.scene else { return nil }
        if scene == "format" { return .detail(.format) }
        if scene == "lenses" { return .detail(.lenses) }
        if scene == "files" { return .detail(.save) }
        if scene == "heat" { return .detail(.heat) }
        if scene.hasSuffix("controls") { return .grid }
        if scene.hasSuffix("edit") { return .edit }
        return nil
    }

    private var unsupportedMessage: String {
        #if targetEnvironment(simulator)
        "The Simulator has no cameras. Run DualShot on an iPhone, or launch it with -DualShotDemo pip."
        #else
        "Recording front and back at once needs an iPhone XS, XR or newer."
        #endif
    }

    // The viewfinder stays in the view tree from the start (even behind the first-launch
    // message), so the preview layers are on screen as soon as the cameras run.
    private var content: some View {
        VStack(spacing: 0) {
            // Video fills a 9:16 frame; photos are 3:4, as in the native Photo mode, with the
            // shutter on black below them.
            ZStack(alignment: .top) {
                viewfinder
                    .aspectRatio(isPhoto ? 3.0 / 4.0 : 9.0 / 16.0, contentMode: .fit)
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { pictureControls }
            .overlay(alignment: .top) { cornerControls }
            bottomBar
                .frame(height: 60)
        }
        .overlay(alignment: .bottom) {
            if sheet != nil {
                ControlsSheet(camera: camera, state: $sheet, draft: $draft)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Tapping outside the sheet closes it, as in the native camera.
        .background {
            if sheet != nil {
                Color.black.opacity(0.001).onTapGesture(perform: closeSheet)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: iconAngle)
        .animation(.spring(duration: 0.4), value: camera.captureMode)
    }

    private var isPhoto: Bool { camera.captureMode == .photo }

    /// The top row as this iPhone can show it (no torch without one, no lens pairs on one lens).
    private var shownEssentials: [CameraControl] {
        camera.essentials.filter(camera.availableControls.contains)
    }

    /// Opens a control's choices, or closes them if they're already open.
    private func open(_ state: SheetState) {
        withAnimation(.spring(duration: 0.35)) { sheet = sheet == state ? nil : state }
    }

    private func closeSheet() {
        withAnimation(.spring(duration: 0.35)) { sheet = nil }
    }

    /// Swiping up from the bottom opens the tools, as in iOS 26.
    private var swipeUpForTools: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            if value.translation.height < -40, abs(value.translation.width) < 60, !camera.isRecording {
                withAnimation(.spring(duration: 0.35)) { sheet = .grid }
            }
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        DualViewfinder(camera: camera, topInset: 52, bottomInset: isPhoto ? 8 : pictureControlsHeight + 8)
            .overlay {
                if let message = camera.interruptionMessage {
                    ZStack {
                        Color.black.opacity(0.75)
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash.fill").font(.system(size: 30))
                            Text(message).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if let countdown = camera.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 120, weight: .thin).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .contentTransition(.numericText(countsDown: true))
                        .rotationEffect(iconAngle)
                        .allowsHitTesting(false)
                }
            }
            .overlay { Color.black.opacity(blink ? 1 : 0).allowsHitTesting(false) }
            .onChange(of: camera.photoID) {
                blink = true
                withAnimation(.easeOut(duration: 0.25).delay(0.05)) { blink = false }
            }
            .animation(.snappy, value: camera.countdown)
            .overlay(alignment: .top) { topControls.padding(.top, 4) }
            .overlay(alignment: .top) {
                Group {
                    if let notice = camera.notice {
                        NoticePill(text: notice)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .task(id: notice) {
                                try? await Task.sleep(for: .seconds(3))
                                camera.notice = nil
                            }
                    } else if camera.frontStopped {
                        NoticePill(text: "Front stopped to cool down · back still recording")
                    }
                }
                .padding(.top, camera.recordingStart == nil ? 12 : 52)
                .padding(.horizontal, 16)
            }
            .animation(.snappy, value: camera.notice)
            .animation(.easeOut(duration: 0.2), value: camera.interruptionMessage)
            .simultaneousGesture(pinchToZoom)
    }

    /// Pinch zooms the back camera, wherever it is on screen.
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? camera.displayZoom
                pinchBase = base
                camera.setDisplayZoom(base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: - Over the picture

    /// The top row beside the Dynamic Island, as in iOS 27: your chosen controls split between
    /// the two corners (torch left and format right to start with). While the sheet is open the
    /// row offers Edit, and while editing, Cancel and Done with the new row below.
    private var cornerControls: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    switch sheet {
                    case .grid:
                        bandButton("Edit") {
                            draft = shownEssentials
                            sheet = .edit
                        }
                        Spacer()
                    case .edit:
                        bandButton("Cancel") { sheet = .grid }
                        Spacer()
                        bandButton("Done", prominent: true) {
                            camera.essentials = draft
                            sheet = .grid
                        }
                    default:
                        let items = shownEssentials
                        let left = (items.count + 1) / 2
                        ForEach(items.prefix(left)) { essential($0) }
                        Spacer(minLength: 130)
                        ForEach(items.dropFirst(left)) { essential($0) }
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: max(44, geo.safeAreaInsets.top))
                if sheet == .edit { draftRow.transition(.opacity) }
            }
            .offset(y: -geo.safeAreaInsets.top)
            .animation(.snappy(duration: 0.25), value: sheet)
            .animation(.snappy(duration: 0.25), value: draft)
        }
    }

    /// One of the top row's controls: toggles flip, the rest open their choices in the sheet.
    private func essential(_ control: CameraControl) -> some View {
        let open = sheet == .detail(control)
        let locked = camera.isRecording && (control == .format || control == .lenses)
        return Button {
            switch control {
            case .torch: camera.toggleTorch()
            case .flash: camera.flashOn.toggle()
            default: self.open(.detail(control))
            }
        } label: {
            ControlGlyph(control: control, camera: camera, size: 19, highlighted: open)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rotationEffect(iconAngle)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityLabel(control.label.capitalized)
    }

    private func bandButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background { if prominent { Capsule().fill(.yellow) } }
                .glass(in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// While editing: the new top row, each control with a minus to take it out.
    private var draftRow: some View {
        HStack(spacing: 14) {
            if draft.isEmpty {
                Text("Tap controls below to add them")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(minHeight: 44)
            }
            ForEach(draft) { control in
                ControlGlyph(control: control, camera: camera, size: 18)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topLeading) {
                        Button { draft.removeAll { $0 == control } } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 17))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: -10, y: -10)
                        .accessibilityLabel("Remove \(control.label.capitalized)")
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glass(in: Capsule())
    }

    private var topControls: some View {
        ZStack {
            if let start = camera.recordingStart {
                RecordingTimer(start: start)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        // Only when it matters ("fair" is a normal, warm iPhone): a thermometer at the edge.
        .overlay(alignment: .trailing) {
            if camera.pressure >= .serious {
                HealthChip(pressure: camera.pressure, size: 34)
                    .rotationEffect(iconAngle)
                    .padding(.trailing, 12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: camera.recordingStart)
        .animation(.easeOut(duration: 0.3), value: camera.pressure)
    }

    /// Zoom buttons and the shutter inside the bottom of the picture, with the tools button beside
    /// the shutter, as in iOS 26.
    private var pictureControls: some View {
        VStack(spacing: 14) {
            if camera.zoomStops.count > 1, camera.layout.backIsMain || camera.layout.style == .split {
                ZoomBar(stops: camera.zoomStops, current: camera.displayZoom, iconAngle: iconAngle) {
                    camera.selectZoom($0)
                }
                .opacity(camera.switchingLens ? 0.5 : 1)
                .transition(.opacity)
            }
            RecordButton(recording: camera.isRecording, photo: isPhoto) {
                if sheet != nil { closeSheet() }
                camera.recordPressed()
            }
            .disabled(camera.interruptionMessage != nil || camera.status != .ready)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                ToolsButton(active: sheet != nil) {
                    withAnimation(.spring(duration: 0.35)) { sheet = sheet == nil ? .grid : nil }
                }
                    .rotationEffect(iconAngle)
                    .padding(.trailing, 26)
            }
        }
        .padding(.bottom, 18)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pictureControlsHeight = $0 }
        .simultaneousGesture(swipeUpForTools)
        .animation(.easeOut(duration: 0.2), value: camera.layout)
    }

    // MARK: - Under the picture

    private var bottomBar: some View {
        HStack {
            ThumbnailButton(image: camera.lastThumbnail, busy: camera.processing > 0) {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            }
            .rotationEffect(iconAngle)
            .accessibilityLabel("Open Photos")

            Spacer(minLength: 8)

            ModeCapsule(mode: camera.captureMode) { mode in
                sheet = nil
                camera.setCaptureMode(mode)
            }
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0 : 1)

            Spacer(minLength: 8)

            GlassIconButton(symbol: "arrow.triangle.2.circlepath", size: 48) {
                camera.swapCameras()
            }
            .rotationEffect(iconAngle)
            .accessibilityLabel("Swap cameras")
        }
        .padding(.horizontal, 24)
        .simultaneousGesture(swipeUpForTools)
    }
}

private struct MessageView: View {
    let symbol: String
    let title: String
    let message: String
    let showsSettings: Bool
    var busy = false

    var body: some View {
        VStack(spacing: 14) {
            if busy {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
            if showsSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
