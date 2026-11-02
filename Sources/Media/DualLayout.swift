import CoreGraphics
import Foundation

enum DualStyle: String, Codable, Sendable {
    /// The main camera fills the frame, the other sits in a small window, like iPhone 17's Dual Capture.
    case pip
    /// One camera on top, the other below.
    case split
}

enum PiPCorner: String, Codable, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    static func nearest(to point: CGPoint, in size: CGSize) -> PiPCorner {
        let top = point.y < size.height / 2
        let leading = point.x < size.width / 2
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}

/// How the two cameras are arranged. The viewfinder shows it and the combined video replays it.
struct DualLayout: Codable, Equatable, Sendable {
    var style: DualStyle = .pip
    var backIsMain = true
    var corner: PiPCorner = .topLeading
}

/// How the phone was held when recording started. The screen stays portrait, so the
/// combined video turns the layout to match.
enum RecordOrientation: String, Codable, Sendable {
    case portrait, landscapeLeft, landscapeRight, upsideDown

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Maps a rect laid out on the portrait screen (`portrait` is that screen's size) into the
    /// recorded frame. Landscape left is the phone turned counterclockwise (top to the left).
    func map(_ r: CGRect, portrait p: CGSize) -> CGRect {
        switch self {
        case .portrait:
            return r
        case .landscapeLeft:
            return CGRect(x: r.minY, y: p.width - r.maxX, width: r.height, height: r.width)
        case .landscapeRight:
            return CGRect(x: p.height - r.maxY, y: r.minX, width: r.height, height: r.width)
        case .upsideDown:
            return CGRect(x: p.width - r.maxX, y: p.height - r.maxY, width: r.width, height: r.height)
        }
    }
}

/// Where each camera sits, with a top-left origin.
struct DualFrames: Equatable {
    var back: CGRect
    var front: CGRect
    /// Which picture is drawn over the other.
    var frontOnTop: Bool
    var backRadius: CGFloat
    var frontRadius: CGFloat
}

struct FrameInsets: Equatable {
    var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat

    static func uniform(_ value: CGFloat) -> FrameInsets {
        FrameInsets(top: value, leading: value, bottom: value, trailing: value)
    }
}

/// One geometry for the screen and the combined video, so what you see is what gets saved.
enum DualGeometry {
    /// The small window's width as a share of the frame's short side.
    static let pipWidth: CGFloat = 0.3
    /// Width / height of the small window as seen on the portrait screen.
    static let pipAspect: CGFloat = 3.0 / 4.0

    /// Lays out `layout` in a portrait frame of `size`. `insets` keep the small window clear
    /// of on-screen controls; the combined video uses even margins.
    static func frames(for layout: DualLayout, in size: CGSize, insets: FrameInsets) -> DualFrames {
        let full = CGRect(origin: .zero, size: size)
        switch layout.style {
        case .split:
            let top = CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
            let bottom = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
            return DualFrames(back: layout.backIsMain ? top : bottom, front: layout.backIsMain ? bottom : top,
                              frontOnTop: true, backRadius: 0, frontRadius: 0)
        case .pip:
            let width = min(size.width, size.height) * pipWidth
            let height = width / pipAspect
            let x = layout.corner.isLeading ? insets.leading : size.width - insets.trailing - width
            let y = layout.corner.isTop ? insets.top : size.height - insets.bottom - height
            let small = CGRect(x: x, y: y, width: width, height: height)
            let radius = width * 0.14
            return layout.backIsMain
                ? DualFrames(back: full, front: small, frontOnTop: true, backRadius: 0, frontRadius: radius)
                : DualFrames(back: small, front: full, frontOnTop: false, backRadius: radius, frontRadius: 0)
        }
    }

    /// The layout in a recorded frame of `canvas`, turned for how the phone was held.
    static func frames(for layout: DualLayout, canvas: CGSize, orientation: RecordOrientation) -> DualFrames {
        let portrait = orientation.isLandscape ? CGSize(width: canvas.height, height: canvas.width) : canvas
        let margin = min(canvas.width, canvas.height) * 0.04
        let f = frames(for: layout, in: portrait, insets: .uniform(margin))
        return DualFrames(back: orientation.map(f.back, portrait: portrait),
                          front: orientation.map(f.front, portrait: portrait),
                          frontOnTop: f.frontOnTop, backRadius: f.backRadius, frontRadius: f.frontRadius)
    }
}

/// Every layout change during a recording, so the combined video can replay them.
struct LayoutTimeline: Codable, Sendable {
    struct Event: Codable, Sendable {
        /// Seconds since the back file started.
        var time: Double
        var layout: DualLayout
    }

    var events: [Event]

    /// How long a change animates in the combined video.
    static let transition = 0.3

    init(start: DualLayout) {
        events = [Event(time: 0, layout: start)]
    }

    /// While recording, `time` is on the session clock; `rebase` moves it onto the take's clock.
    mutating func append(_ layout: DualLayout, at time: Double) {
        guard events.last?.layout != layout else { return }
        events.append(Event(time: max(time, events.last?.time ?? 0), layout: layout))
    }

    /// The first event is the layout at the start; every later one becomes seconds after `base`.
    mutating func rebase(_ base: Double) {
        for index in events.indices.dropFirst() {
            events[index].time = max(0, events[index].time - base)
        }
    }

    func layout(at time: Double) -> DualLayout {
        (events.last { $0.time <= time } ?? events[0]).layout
    }

    /// The frames at `time`, mid-animation if a change just happened.
    func frames(at time: Double, canvas: CGSize, orientation: RecordOrientation) -> DualFrames {
        let index = events.lastIndex { $0.time <= time } ?? 0
        let current = DualGeometry.frames(for: events[index].layout, canvas: canvas, orientation: orientation)
        let elapsed = time - events[index].time
        guard index > 0, elapsed < Self.transition else { return current }
        let previous = DualGeometry.frames(for: events[index - 1].layout, canvas: canvas, orientation: orientation)
        let t = elapsed / Self.transition
        let eased = CGFloat(t * t * (3 - 2 * t))
        return DualFrames(back: previous.back.lerp(to: current.back, eased),
                          front: previous.front.lerp(to: current.front, eased),
                          frontOnTop: current.frontOnTop,
                          backRadius: previous.backRadius + (current.backRadius - previous.backRadius) * eased,
                          frontRadius: previous.frontRadius + (current.frontRadius - previous.frontRadius) * eased)
    }

    /// When the main camera changes, so the combined video's sound can follow it.
    /// Each entry says whether the front microphone leads from that time on.
    var audioSwitches: [(time: Double, front: Bool)] {
        var result: [(time: Double, front: Bool)] = []
        for event in events {
            let front = event.layout.style == .pip && !event.layout.backIsMain
            if result.last?.front != front { result.append((event.time, front)) }
        }
        return result
    }
}

private extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t, y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t, height: height + (other.height - height) * t)
    }
}
