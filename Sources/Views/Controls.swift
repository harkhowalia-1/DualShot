import SwiftUI

// MARK: - Liquid Glass with a material fallback for older systems

extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(tint?.opacity(0.6) ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A round glass button, as in SmartShot.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 38
    var tint: Color? = nil
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .glass(in: Circle(), tint: tint)
                // Small buttons still get a full 44-point target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// iOS 26's camera tools button: six dots in a glass circle. SF Symbols has no six-dot glyph,
/// so it's drawn here.
struct ToolsButton: View {
    let active: Bool
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 4, height: 4) }
                    }
                }
            }
            .foregroundStyle(active ? .yellow : .white)
            .frame(width: size, height: size)
            .glass(in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera settings")
    }
}

// MARK: - Record button

/// The native video shutter: a red dot that turns into a red square while recording.
struct RecordButton: View {
    let recording: Bool
    /// Photo mode's plain white shutter.
    var photo = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: recording ? 7 : 32, style: .continuous)
                    .fill(photo ? Color.white : Color.red)
                    .frame(width: recording ? 30 : 64, height: recording ? 30 : 64)
                    .animation(.spring(duration: 0.3), value: recording)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: recording)
        .accessibilityLabel(photo ? "Take photo" : recording ? "Stop recording" : "Record")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Zoom

struct ZoomBar: View {
    let stops: [ZoomStop]
    let current: CGFloat
    var iconAngle: Angle = .zero
    let select: (ZoomStop) -> Void

    /// As in the native camera: plain numbers over the picture, the current one yellow in a dark circle.
    var body: some View {
        HStack(spacing: 2) {
            ForEach(stops) { stop in
                let active = activeStop?.id == stop.id
                Button { select(stop) } label: {
                    Text(active ? activeLabel : stop.label)
                        .font(.system(size: active ? 14 : 15, weight: .semibold))
                        .foregroundStyle(active ? .yellow : .white)
                        .shadow(color: .black.opacity(active ? 0 : 0.45), radius: 2)
                        .rotationEffect(iconAngle)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(active ? 0.4 : 0), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(stop.label)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .animation(.spring(duration: 0.25), value: current)
    }

    private var activeStop: ZoomStop? {
        stops.last { $0.display <= current + 0.01 } ?? stops.first
    }

    private var activeLabel: String {
        let value = (current * 10).rounded() / 10
        if value < 1 { return String(format: ".%d×", Int((value * 10).rounded())) }
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

// MARK: - Thumbnail

/// The latest recording. Tapping it opens Photos, where the videos are saved.
struct ThumbnailButton: View {
    let image: UIImage?
    let busy: Bool
    let action: () -> Void

    /// Round, as in iOS 26.
    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            .overlay {
                if busy {
                    // Still combining and saving the last take.
                    ZStack {
                        Circle().fill(.black.opacity(0.45))
                        ProgressView().tint(.white)
                    }
                    .transition(.opacity)
                }
            }
            .id(image.map(ObjectIdentifier.init))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.35), value: image.map(ObjectIdentifier.init))
        .animation(.easeOut(duration: 0.2), value: busy)
    }
}

// MARK: - Status

/// The yellow pill at the top of the viewfinder, as in SmartShot.
struct NoticePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow, in: Capsule())
    }
}

/// The native camera's red recording timer.
struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// Appears in the top bar as the iPhone warms up.
struct HealthChip: View {
    let pressure: PressureLevel
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: pressure >= .serious ? "thermometer.high" : "thermometer.medium")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: pressure >= .critical)
            .frame(width: size, height: size)
            .glass(in: Circle())
            .accessibilityLabel(pressure >= .serious ? "iPhone is hot" : "iPhone is warm")
    }

    private var color: Color {
        switch pressure {
        case .critical, .shutdown: .red
        case .serious: .orange
        default: .yellow
        }
    }
}

/// The yellow square the native camera shows where you tap to focus.
struct FocusSquare: View {
    @State private var settled = false
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(.yellow, lineWidth: 1.2)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.4)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .task {
                withAnimation(.spring(duration: 0.3)) { settled = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
    }
}

// MARK: - Native camera pieces

/// The native camera's format readout: "4K" over a small "30", plain over the picture.
/// As in iOS 26, tapping it opens the FORMAT panel rather than stepping through values.
struct FormatButton: View {
    let mode: VideoMode
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: -1) {
                Text(mode.resolutionLabel)
                    .font(.system(size: 17, weight: .semibold))
                Text("\(mode.fps)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(open ? .yellow : .white)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .contentTransition(.numericText())
            .frame(minWidth: 56, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: mode)
        .accessibilityLabel("Video format, \(mode.resolutionLabel), \(mode.fps) frames per second")
        .accessibilityHint("Opens the format settings")
    }
}

/// A plain glyph over the picture, like the native camera's flash button.
struct PlainIconButton: View {
    let symbol: String
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// iOS 26's mode switcher: a glass capsule under the picture, the chosen mode yellow on a
/// darker pill that slides between them.
struct ModeCapsule: View {
    let mode: CaptureMode
    let select: (CaptureMode) -> Void

    @Namespace private var selection
    private static let items: [(mode: CaptureMode, name: String)] = [(.video, "VIDEO"), (.photo, "PHOTO")]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.mode) { item in
                let chosen = item.mode == mode
                Button { select(item.mode) } label: {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(chosen ? Color.yellow : Color.white)
                        .frame(width: 88, height: 40)
                        .background {
                            if chosen {
                                Capsule().fill(.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "chosen", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .animation(.snappy(duration: 0.25), value: mode)
        // Swipe sideways to change mode, as in the native camera.
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.width < -30 { select(.photo) }
            if value.translation.width > 30 { select(.video) }
        })
    }
}
