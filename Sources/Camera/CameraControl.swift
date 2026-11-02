import Foundation

enum CaptureMode: String, Codable {
    case video, photo
}

/// The camera's controls, as iOS 27 arranges them: all of them in the six-dot sheet, and the
/// ones you pick in the top row beside the Dynamic Island ("Essentials"), separately per mode.
enum CameraControl: String, Codable, CaseIterable, Identifiable {
    case torch, flash, format, photoFormat, timer, layout, lenses, save, heat

    var id: String { rawValue }

    var modes: Set<CaptureMode> {
        switch self {
        case .torch, .format, .heat: [.video]
        case .flash, .photoFormat, .timer: [.photo]
        case .layout, .lenses, .save: [.video, .photo]
        }
    }

    /// The small uppercase label under the control in the sheet.
    var label: String {
        switch self {
        // The video light is "Flash" too, as in the native camera.
        case .torch, .flash: "FLASH"
        case .format, .photoFormat: "FORMAT"
        case .timer: "TIMER"
        case .layout: "LAYOUT"
        case .lenses: "BACK LENSES"
        case .save: "EXPORT OPTIONS"
        case .heat: "HEAT-UP SETTINGS"
        }
    }

    /// On/off controls flip with a tap; the rest open their choices.
    var isToggle: Bool { self == .torch || self == .flash }

    /// The top row beside the Dynamic Island holds this many at most.
    static let maxEssentials = 6

    static func defaultEssentials(_ mode: CaptureMode) -> [CameraControl] {
        mode == .video ? [.torch, .format] : [.flash, .photoFormat]
    }
}
