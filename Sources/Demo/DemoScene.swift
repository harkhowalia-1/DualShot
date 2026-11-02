import SwiftUI

/// Debug-only staged scenes, for the Simulator (which has no cameras) and screenshots.
/// Launch with `-DualShotDemo pip|split|recording|format|hot`.
enum DemoMode {
    static var scene: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DualShotDemo"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }
}

/// A drawn stand-in for a camera feed, in SmartShot's flat illustration style.
struct DemoFeed: View {
    enum Kind { case back, front }
    let kind: Kind

    var body: some View {
        switch kind {
        case .back: landscape
        case .front: selfie
        }
    }

    /// The back camera: a sunset over the hills.
    private var landscape: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.80, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Color(red: 1, green: 0.93, blue: 0.75))
                    .frame(width: w * 0.32)
                    .blur(radius: w * 0.02)
                    .position(x: w * 0.68, y: h * 0.42)
                Hills(peaks: [0.62, 0.5, 0.58, 0.46, 0.6])
                    .fill(Color(red: 0.42, green: 0.36, blue: 0.55))
                Hills(peaks: [0.72, 0.66, 0.7, 0.64, 0.74])
                    .fill(Color(red: 0.30, green: 0.50, blue: 0.42))
                Rectangle()
                    .fill(Color(red: 0.24, green: 0.42, blue: 0.34))
                    .frame(height: h * 0.2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// The front camera: the person holding the phone.
    private var selfie: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let head = min(w, h) * 0.46
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.20, green: 0.24, blue: 0.34)],
                               startPoint: .top, endPoint: .bottom)
                // Shoulders
                Capsule()
                    .fill(Color(red: 0.95, green: 0.45, blue: 0.36))
                    .frame(width: w * 0.95, height: h * 0.5)
                    .position(x: w / 2, y: h * 0.98)
                // Head
                Circle()
                    .fill(Color(red: 0.93, green: 0.76, blue: 0.62))
                    .frame(width: head, height: head)
                    .position(x: w / 2, y: h * 0.48)
                // Hair
                Circle()
                    .trim(from: 0.5, to: 1)
                    .fill(Color(red: 0.30, green: 0.20, blue: 0.14))
                    .frame(width: head * 1.06, height: head * 1.06)
                    .position(x: w / 2, y: h * 0.48 - head * 0.06)
                // Eyes and smile
                HStack(spacing: head * 0.26) {
                    Circle().frame(width: head * 0.09)
                    Circle().frame(width: head * 0.09)
                }
                .foregroundStyle(Color(red: 0.2, green: 0.15, blue: 0.12))
                .position(x: w / 2, y: h * 0.49)
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(Color(red: 0.35, green: 0.18, blue: 0.14), style: StrokeStyle(lineWidth: head * 0.04, lineCap: .round))
                    .frame(width: head * 0.4, height: head * 0.4)
                    .position(x: w / 2, y: h * 0.5)
            }
        }
    }
}

private struct Hills: Shape {
    /// Peak heights as a share of the height, left to right.
    let peaks: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let step = rect.width / CGFloat(peaks.count - 1)
        var previous = CGPoint(x: rect.minX, y: rect.minY + rect.height * peaks[0])
        path.addLine(to: previous)
        for (i, peak) in peaks.enumerated().dropFirst() {
            let point = CGPoint(x: rect.minX + step * CGFloat(i), y: rect.minY + rect.height * peak)
            path.addQuadCurve(to: point, control: CGPoint(x: (previous.x + point.x) / 2, y: min(previous.y, point.y) - rect.height * 0.05))
            previous = point
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
