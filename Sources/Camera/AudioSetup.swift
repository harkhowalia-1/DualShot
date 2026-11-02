import AVFoundation

/// The app sets up its own audio session instead of letting the capture session do it:
/// - It shares audio with other apps, so music or a video playing in your headphones keeps going
///   (and can't make iOS refuse the microphone, which used to stop the cameras every second).
/// - It records from the iPhone's own microphones even with Bluetooth headphones on, like the
///   native camera, so each camera keeps its own beamformed sound.
enum AudioSetup {
    /// Nil when the app can record sound; otherwise why iOS refused (a call has priority).
    static func activate() -> String? {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .allowBluetoothA2DP])
            if let builtIn = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? audio.setPreferredInput(builtIn)
            }
            try audio.setActive(true)
            return nil
        } catch {
            let code = (error as NSError).code
            let fourCC = String(bytes: withUnsafeBytes(of: UInt32(truncatingIfNeeded: code).bigEndian, Array.init), encoding: .ascii) ?? ""
            return "\(code) '\(fourCC)'"
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// For the diagnostics report.
    static var summary: String {
        let audio = AVAudioSession.sharedInstance()
        return "category \(audio.category.rawValue) mode \(audio.mode.rawValue) otherPlaying \(audio.isOtherAudioPlaying) "
            + "in \(audio.currentRoute.inputs.map(\.portType.rawValue)) out \(audio.currentRoute.outputs.map(\.portType.rawValue))"
    }
}
