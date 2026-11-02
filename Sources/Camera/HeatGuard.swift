import AVFoundation

/// How hot the cameras are running, from the cameras' own system pressure reports.
enum PressureLevel: Int, Comparable, Codable {
    case nominal, fair, serious, critical, shutdown

    init(_ level: AVCaptureDevice.SystemPressureState.Level) {
        switch level {
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        case .shutdown: self = .shutdown
        default: self = .nominal
        }
    }

    static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What to do when the iPhone gets hot.
enum HeatPolicy: String, Codable, CaseIterable, Identifiable {
    /// Step down smoothly so the recording keeps going.
    case smart
    /// Keep the chosen quality until iOS itself has to stop the cameras.
    case force

    var id: String { rawValue }
    var label: String { self == .smart ? "Smart" : "Force" }

    /// How the Heat-Up Settings control names and explains each choice.
    var title: String { self == .smart ? "On" : "Off" }

    var detail: String {
        self == .smart
            ? "When the iPhone gets hot, the frame rate lowers so recording keeps going"
            : "Keeps your quality until iOS has to stop the cameras itself"
    }
}

/// Decides how to keep a recording going as the iPhone heats up. Pure logic: the camera
/// model asks it on every pressure change, and again every so often while it stays hot,
/// so each call can step down one more notch.
struct HeatGuard {
    enum Action: Equatable {
        case setFrameRate(Int)
        /// Close the front file; the back keeps recording.
        case stopFront
        case warn(String)
    }

    var policy: HeatPolicy

    /// The slowed-down preview frame rate while not recording, as Apple's camera sample does.
    static let coolingPreviewFPS = 20

    func actions(level: PressureLevel, recording: Bool, fps: Int, modeFPS: Int, frontRunning: Bool) -> [Action] {
        guard recording else {
            if level >= .serious, fps > Self.coolingPreviewFPS { return [.setFrameRate(Self.coolingPreviewFPS)] }
            if level <= .fair, fps != modeFPS { return [.setFrameRate(modeFPS)] }
            return []
        }
        switch policy {
        case .smart:
            switch level {
            case .serious:
                if fps > 30 { return [.setFrameRate(30)] }
                if fps > 24 { return [.setFrameRate(24)] }
                return []
            case .critical:
                var actions: [Action] = []
                if fps > 24 { actions.append(.setFrameRate(24)) }
                if frontRunning { actions.append(.stopFront) }
                return actions
            default:
                return []
            }
        case .force:
            return level == .critical ? [.warn("Very hot. iOS may stop the cameras soon.")] : []
        }
    }
}
