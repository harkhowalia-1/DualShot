import AVFoundation

/// What ends up in Photos after a recording.
enum SaveOption: String, Codable, CaseIterable, Identifiable {
    /// The back and front files, plus the combined video.
    case all
    /// Just the two camera files, for editing.
    case angles
    /// Just the combined video, like the native Dual Capture.
    case combined

    var id: String { rawValue }

    /// How the Export Options control names and explains each choice.
    var title: String {
        switch self {
        case .all: "Separate + Combined"
        case .angles: "Separate Only"
        case .combined: "Combined Only"
        }
    }

    var detail: String {
        switch self {
        case .all: "The back and front as their own files, plus one with both"
        case .angles: "The back and front as their own files, for editing"
        case .combined: "One file with both cameras, like Dual Capture"
        }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .angles: "Angles"
        case .combined: "Combined"
        }
    }
}

enum CameraSide: String, Codable {
    case back, front
}

/// One recording: the camera files, how they line up and how the screen was laid out.
/// Written next to the files as take.json, so a recording interrupted by a crash can be finished later.
struct Take: Codable {
    /// One file from one camera. The back camera starts a new file each time it switches
    /// lens pairs (on iPhones that can't run every lens next to the front camera).
    struct Segment: Codable {
        var camera: CameraSide
        var file: String
        var lens: BackLens?
        /// When the file started, in seconds on the session clock.
        var clock: Double?
        /// Seconds after the take's first back file started. Set when the take is finished.
        var start: Double?
    }

    var id: String
    var date: Date
    var mode: VideoMode
    var codec: VideoCodec
    var save: SaveOption
    var orientation: RecordOrientation
    var timeline: LayoutTimeline
    var segments: [Segment] = []
    /// Heat-guard steps and lens switches during the recording.
    var notes: [String] = []
    /// A debug self-test recording: kept out of Photos.
    var isTest: Bool?

    init(mode: VideoMode, codec: VideoCodec, save: SaveOption, orientation: RecordOrientation, layout: DualLayout) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        date = Date()
        id = "DS_" + formatter.string(from: date)
        self.mode = mode
        self.codec = codec
        self.save = save
        self.orientation = orientation
        timeline = LayoutTimeline(start: layout)
    }

    static var root: URL {
        URL.documentsDirectory.appendingPathComponent("Takes", isDirectory: true)
    }

    var folder: URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    var combinedURL: URL { folder.appendingPathComponent("\(id)_Combined.mov") }
    private var infoURL: URL { folder.appendingPathComponent("take.json") }

    func url(of segment: Segment) -> URL { folder.appendingPathComponent(segment.file) }

    func segments(of camera: CameraSide) -> [Segment] {
        segments.filter { $0.camera == camera && FileManager.default.fileExists(atPath: url(of: $0).path) }
    }

    /// Adds the next file for `camera` and returns its URL.
    mutating func addSegment(_ camera: CameraSide, lens: BackLens?) -> URL {
        let count = segments.filter { $0.camera == camera }.count
        let name = camera == .back ? "Back" : "Front"
        let file = count == 0 ? "\(id)_\(name).mov" : "\(id)_\(name)-\(count + 1).mov"
        let segment = Segment(camera: camera, file: file, lens: lens)
        segments.append(segment)
        return url(of: segment)
    }

    mutating func started(_ url: URL, clock: Double) {
        guard let index = segments.firstIndex(where: { $0.file == url.lastPathComponent }) else { return }
        segments[index].clock = clock
    }

    /// Puts every time on the take's own clock: zero is when the first back file started.
    mutating func settleTimes() {
        let clocks = segments.compactMap(\.clock)
        guard let base = segments.first(where: { $0.camera == .back })?.clock ?? clocks.min() else {
            for index in segments.indices { segments[index].start = 0 }
            return
        }
        for index in segments.indices {
            segments[index].start = (segments[index].clock ?? base) - base
        }
        timeline.rebase(base)
    }

    func createFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: infoURL, options: .atomic)
    }

    /// Leaves the files in place but stops treating them as unfinished.
    func forgetInfo() {
        try? FileManager.default.removeItem(at: infoURL)
    }

    /// Takes still on disk that never made it to Photos: interrupted by a crash, a force-quit,
    /// or postponed while the next recording ran.
    static func leftovers() -> [Take] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("take.json")) else { return nil }
            return try? decoder.decode(Take.self, from: data)
        }
    }
}

/// Reports each camera file starting and finishing. One per take; it outlives lens switches.
final class TakeRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    /// A file started, at this time on the session clock (exact on iOS 18.2+, close before).
    var onStart: (@Sendable (URL, Double) -> Void)?
    /// A file was closed; `ok` if it's playable.
    var onFinish: (@Sendable (URL, Bool) -> Void)?

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        onStart?(fileURL, CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    @available(iOS 18.2, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime,
                    from connections: [AVCaptureConnection]) {
        onStart?(fileURL, startPTS.seconds)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // An error can still mean a good file (for example when the disk filled up).
        var ok = error == nil
        if let error = error as NSError?,
           let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            ok = finished
        }
        onFinish?(url, ok && FileManager.default.fileExists(atPath: url.path))
    }
}
