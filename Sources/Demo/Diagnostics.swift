#if DEBUG
import QuartzCore
import UIKit

/// Debug builds only. Every few seconds, writes what the camera is doing (preview and recording
/// angles, formats, frame rates, heat, dropped screen frames, recent events) to
/// Library/Caches/diagnostics.json, so it can be read off a connected iPhone with
/// `xcrun devicectl device copy from`, without needing to see the screen.
@MainActor
final class Diagnostics: NSObject {
    static let shared = Diagnostics()

    private weak var camera: DualCamera?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var lastTimestamp: CFTimeInterval = 0
    private var window = (frames: 0, hitches: 0, worst: 0.0)
    private var total = (frames: 0, hitches: 0, worst: 0.0)
    private var events: [String] = []
    private let started = Date()

    func attach(_ camera: DualCamera) {
        guard self.camera == nil else { return }
        self.camera = camera
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        log("diagnostics attached")
    }

    func log(_ text: String) {
        events.append(String(format: "%6.1fs ", Date().timeIntervalSince(started)) + text)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }

    /// Who has the audio system, to explain microphone refusals.
    func logAudioSession() {
        log("audio: " + AudioSetup.summary)
    }

    /// Counts screen frames the app missed (the main thread was busy and the UI stuttered).
    /// ProMotion screens deliver callbacks on a 120 Hz grid, so a single late callback that the
    /// next one makes up for isn't a dropped frame: only whole missing frames count.
    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0, link.duration > 0, UIApplication.shared.applicationState == .active else { return }
        let interval = link.timestamp - lastTimestamp
        let missed = max(0, Int((interval / link.duration).rounded()) - 1)
        window.frames += 1
        total.frames += 1
        window.hitches += missed
        total.hitches += missed
        window.worst = max(window.worst, interval)
        total.worst = max(total.worst, interval)
    }

    private func write() {
        guard let camera else { return }
        Task { await write(camera) }
    }

    private func write(_ camera: DualCamera) async {
        var info = await camera.diagnosticsSnapshot()
        info["uptime"] = Int(Date().timeIntervalSince(started))
        info["screen"] = [
            "frameMs": Int(((link?.duration ?? 0) * 1000).rounded()),
            "last3s": ["frames": window.frames, "missedFrames": window.hitches, "worstMs": Int(window.worst * 1000)],
            "total": ["frames": total.frames, "missedFrames": total.hitches, "worstMs": Int(total.worst * 1000)],
        ]
        window = (0, 0, 0)
        info["events"] = events
        let url = URL.cachesDirectory.appendingPathComponent("diagnostics.json")
        if JSONSerialization.isValidJSONObject(info),
           let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
