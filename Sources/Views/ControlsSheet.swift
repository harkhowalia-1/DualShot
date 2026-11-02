import SwiftUI

/// What the six-dot sheet is showing.
enum SheetState: Equatable {
    /// Every control of the current mode, three to a row (iOS 27).
    case grid
    /// One control's choices.
    case detail(CameraControl)
    /// Choosing the controls for the top row ("ADD VIDEO CONTROLS").
    case edit
}

/// A control's icon: an SF Symbol, or its current value as text (like iOS 27's "HEIF 24").
struct ControlGlyph: View {
    let control: CameraControl
    let camera: DualCamera
    var size: CGFloat = 19
    /// Yellow while this control's choices are open.
    var highlighted = false

    private var tint: Color { highlighted ? .yellow : .white }

    var body: some View {
        switch control {
        case .torch:
            Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(camera.torchOn ? Color.yellow : Color.white)
        case .flash:
            Image(systemName: camera.flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(camera.flashOn ? Color.yellow : Color.white)
        case .format:
            stacked(camera.displayMode.resolutionLabel, "\(camera.displayMode.fps)")
        case .photoFormat:
            stacked(camera.photoFormat.label, megapixels)
        case .timer:
            if camera.timerSeconds == 0 {
                symbol("timer")
            } else {
                Text("\(camera.timerSeconds)s")
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
        case .layout:
            symbol(camera.layout.style == .pip ? "pip" : "rectangle.split.1x2")
        case .lenses:
            // The pair's two lenses as small rings, like the zoom buttons: ".5 1" or "1 3".
            HStack(spacing: -3) {
                ForEach(lensMarks, id: \.self) { mark in
                    Text(mark)
                        .font(.system(size: size * 0.5, weight: .bold))
                        .frame(width: size * 1.05, height: size * 1.05)
                        .overlay(Circle().strokeBorder(tint, lineWidth: 1.3))
                }
            }
            .foregroundStyle(tint)
        case .save:
            symbol(camera.save == .combined ? "rectangle.on.rectangle" : "square.stack.3d.up")
        case .heat:
            symbol(camera.heatPolicy == .smart ? "thermometer.medium" : "flame")
        }
    }

    private var lensMarks: [String] {
        guard let lens = camera.displayLens else { return [] }
        switch lens {
        case .dualWide: return [".5", "1"]
        case .dual:
            let top = camera.zoomRange(of: lens).split(separator: "–").last.map(String.init) ?? "3×"
            return ["1", top.replacingOccurrences(of: "×", with: "")]
        default: return ["1"]
        }
    }

    private var megapixels: String {
        let mp = camera.photoMegapixels.back
        return mp > 0 ? "\(Int(mp.rounded()))MP" : ""
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint)
    }

    private func stacked(_ top: String, _ bottom: String) -> some View {
        VStack(spacing: -1) {
            Text(top).font(.system(size: size * 0.82, weight: .semibold))
            Text(bottom).font(.system(size: size * 0.55, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
    }
}

/// iOS 27's six-dot sheet: a frosted panel that rises from the bottom with a grab handle, every
/// control of the current mode in a three-column grid, each control's choices one tap in, and an
/// Edit view for the top row. Swipe down or tap outside to close.
struct ControlsSheet: View {
    let camera: DualCamera
    @Binding var state: SheetState?
    /// While editing: the top row as it will be after Done.
    @Binding var draft: [CameraControl]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5)
                .accessibilityHidden(true)
            switch state {
            case .grid: grid
            case .detail(let control): detail(control)
            case .edit: edit
            case nil: EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(maxWidth: 520)
        .background(Color(white: 0.11).opacity(0.9), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > 40 { close() }
        })
        .animation(.snappy(duration: 0.25), value: state)
    }

    private func close() {
        withAnimation(.spring(duration: 0.35)) { state = nil }
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(camera.availableControls) { control in
                tile(control, dimmed: false) { activate(control) }
            }
        }
        .padding(.vertical, 6)
    }

    private func tile(_ control: CameraControl, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ControlGlyph(control: control, camera: camera)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.35), in: Circle())
                Text(control.label)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.white)
            }
            .opacity(dimmed ? 0.35 : 1)
            .frame(maxWidth: .infinity, minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.label.capitalized)
    }

    /// Toggles flip; everything else opens its choices.
    private func activate(_ control: CameraControl) {
        switch control {
        case .torch: camera.toggleTorch()
        case .flash: camera.flashOn.toggle()
        default: state = .detail(control)
        }
    }

    // MARK: Detail

    private func detail(_ control: CameraControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Text(control.label)
                    .font(.system(size: 15, weight: .medium))
                    .kerning(1)
                    .foregroundStyle(.white)
                HStack {
                    GlassIconButton(symbol: "chevron.left", size: 38) { state = .grid }
                        .accessibilityLabel("Back")
                    Spacer()
                }
            }
            .padding(.bottom, 6)
            choices(for: control)
            if let note = note(for: control) {
                Text(note)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func choices(for control: CameraControl) -> some View {
        switch control {
        case .format:
            if let capabilities = camera.capabilities {
                let shown = camera.displayMode
                if capabilities.heights.count > 1 {
                    OptionRow(title: "RESOLUTION", options: capabilities.heights, selected: shown.height,
                              label: { VideoMode(height: $0, fps: 30).resolutionLabel }) { height in
                        camera.select(capabilities.mode(height: height, keeping: shown.fps))
                    }
                }
                OptionRow(title: "FRAME RATE", options: capabilities.fpsOptions(height: shown.height),
                          selected: shown.fps, label: { "\($0)" }) { fps in
                    camera.select(VideoMode(height: shown.height, fps: fps))
                }
            }
            OptionRow(title: "CODEC", options: VideoCodec.allCases, selected: camera.codec,
                      label: { $0.label }) { camera.select($0) }
        case .photoFormat:
            OptionRow(title: "FORMAT", options: PhotoFormat.allCases, selected: camera.photoFormat,
                      label: { $0.label }) { camera.select($0) }
        case .timer:
            OptionRow(title: "TIMER", options: [0, 3, 10], selected: camera.timerSeconds,
                      label: { $0 == 0 ? "Off" : "\($0)s" }) { camera.selectTimer($0) }
        case .layout:
            OptionRow(title: "LAYOUT", options: [DualStyle.pip, .split], selected: camera.layout.style,
                      label: { $0 == .pip ? "PiP" : "Split" }) { camera.setStyle($0) }
        case .lenses:
            if let shown = camera.displayLens {
                ChoiceList(options: camera.lensChoices, selected: shown,
                           title: { $0.pairName },
                           detail: { "Zoom " + camera.zoomRange(of: $0).replacingOccurrences(of: "–", with: " to ") },
                           choose: { camera.selectLens($0) })
            }
        case .save:
            ChoiceList(options: SaveOption.allCases, selected: camera.save,
                       title: { $0.title }, detail: { $0.detail }, choose: { camera.select($0) })
        case .heat:
            ChoiceList(options: HeatPolicy.allCases, selected: camera.heatPolicy,
                       title: { $0.title }, detail: { $0.detail }, choose: { camera.select($0) })
        case .torch, .flash:
            EmptyView()
        }
    }

    private func note(for control: CameraControl) -> String? {
        switch control {
        case .format:
            guard let plan = camera.capabilities?.plan(for: camera.displayMode) else { return nil }
            var parts = [plan.isSustainable ? "Runs cool on this iPhone." : "Runs hot: may slow down after a few minutes."]
            if plan.frontHeight < plan.mode.height {
                parts.append("The front camera records \(VideoMode(height: plan.frontHeight, fps: 30).resolutionLabel), its most with two cameras.")
            }
            if let minutes = camera.minutesLeft {
                parts.append("About \(minutes >= 120 ? "\(minutes / 60) h" : "\(minutes) min") of space.")
            }
            return parts.joined(separator: " ")
        case .photoFormat:
            let mp = camera.photoMegapixels
            guard mp.back > 0 else { return nil }
            return String(format: "With both cameras on, this iPhone takes %.0f MP photos with the back camera and %.0f MP with the front.", mp.back, mp.front)
        case .lenses:
            return "While the front camera is on, this iPhone can only run two of its three back lenses. Pick the pair you'll use most. Tapping a zoom button from the other pair switches over by itself, even while recording."
        default:
            return nil
        }
    }

    // MARK: Edit

    private var edit: some View {
        VStack(spacing: 16) {
            Text(camera.captureMode == .video ? "ADD VIDEO CONTROLS" : "ADD PHOTO CONTROLS")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.white)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(camera.availableControls) { control in
                    let added = draft.contains(control)
                    tile(control, dimmed: added) {
                        if !added, draft.count < CameraControl.maxEssentials { draft.append(control) }
                    }
                    .disabled(added)
                }
            }
            Button("Reset to Essentials") { draft = CameraControl.defaultEssentials(camera.captureMode) }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 40)
                .glass(in: Capsule())
                .buttonStyle(.plain)
        }
    }
}

/// Choices that need a sentence each: one row per choice with a name and what it does, the
/// chosen one yellow with a check.
struct ChoiceList<Value: Hashable>: View {
    let options: [Value]
    let selected: Value
    let title: (Value) -> String
    let detail: (Value) -> String
    let choose: (Value) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(options, id: \.self) { value in
                let chosen = value == selected
                Button { choose(value) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(value))
                                .font(.system(size: 16, weight: .semibold))
                            Text(detail(value))
                                .font(.system(size: 13, weight: .medium))
                                .opacity(0.7)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .opacity(chosen ? 1 : 0)
                    }
                    .foregroundStyle(chosen ? Color.yellow : Color.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 54)
                    .background(.white.opacity(chosen ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

/// One row of choices: a label, then options with a yellow dot on the chosen one.
struct OptionRow<Value: Hashable>: View {
    let title: String
    let options: [Value]
    let selected: Value
    let label: (Value) -> String
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .kerning(0.8)
                .foregroundStyle(.white)
                .frame(width: 100, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 14) {
                ForEach(options, id: \.self) { value in
                    let chosen = value == selected
                    Button { choose(value) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(.yellow).frame(width: 5, height: 5).opacity(chosen ? 1 : 0)
                            Text(label(value))
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(chosen ? .yellow : .white)
                        .frame(minWidth: 52, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title.capitalized): \(label(value))")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }
}
