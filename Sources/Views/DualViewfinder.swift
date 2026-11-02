import SwiftUI

/// Both cameras, as picture-in-picture or split. The pictures are UIKit layers
/// (`DualPreviewContainer`); SwiftUI only adds invisible touch areas on top.
/// Drag the small window to any corner, tap it to swap, tap the big picture to focus.
struct DualViewfinder: View {
    let camera: DualCamera
    /// How far the controls over the picture reach in from the top and bottom, so the small
    /// window stays clear of them.
    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let insets = FrameInsets(top: max(12, topInset), leading: 12, bottom: max(12, bottomInset), trailing: 12)
            let frames = DualGeometry.frames(for: camera.layout, in: geo.size, insets: insets)
            let pip = camera.layout.style == .pip
            ZStack(alignment: .topLeading) {
                DualPreview(container: camera.previewContainer, layout: camera.layout, insets: insets,
                            dragOffset: dragOffset, onCaptureButton: { camera.recordPressed() })

                touchArea(back: true, frame: frames.back, small: pip && !camera.layout.backIsMain, in: geo.size)
                    .zIndex(frames.frontOnTop ? 0 : 1)
                touchArea(back: false, frame: frames.front, small: pip && camera.layout.backIsMain, in: geo.size)
                    .zIndex(frames.frontOnTop ? 1 : 0)

                if let mark = camera.focusMark {
                    let frame = mark.onBack ? frames.back : frames.front
                    FocusSquare()
                        .id(mark.id)
                        .position(x: frame.minX + mark.point.x * frame.width, y: frame.minY + mark.point.y * frame.height)
                        .zIndex(2)
                }
            }
        }
    }

    private func touchArea(back: Bool, frame: CGRect, small: Bool, in size: CGSize) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if small {
                    camera.swapCameras()
                } else if frame.width > 0, frame.height > 0 {
                    camera.focus(at: CGPoint(x: location.x / frame.width, y: location.y / frame.height), onBack: back)
                }
            }
            .gesture(moveWindow(frame: frame, in: size), including: small ? .all : .subviews)
            // In split view there's no small window to tap, so a double tap swaps.
            .simultaneousGesture(TapGesture(count: 2).onEnded { camera.swapCameras() },
                                 including: camera.layout.style == .split ? .all : .subviews)
            .offset(x: frame.minX + (small ? dragOffset.width : 0), y: frame.minY + (small ? dragOffset.height : 0))
            .accessibilityElement()
            .accessibilityLabel(back ? "Back camera" : "Front camera")
            .accessibilityHint(small ? "Tap to swap, drag to move" : "Tap to focus")
            .accessibilityAddTraits(.isButton)
    }

    /// The small window follows your finger, then settles into the nearest corner.
    /// The movement is measured against the whole screen: measured against the window itself, it
    /// changes as the window moves and the window jitters back and forth under the finger.
    private func moveWindow(frame: CGRect, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let center = CGPoint(x: frame.midX + value.translation.width + value.velocity.width * 0.1,
                                     y: frame.midY + value.translation.height + value.velocity.height * 0.1)
                dragOffset = .zero
                camera.movePiP(to: PiPCorner.nearest(to: center, in: size))
            }
    }
}
