import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// A view whose own layer is the camera preview, so moving or resizing it is plain Core Animation.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    /// Built up front: creating it the first time it's needed cost a visible hiccup.
    private let blur = UIVisualEffectView(effect: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.isUserInteractionEnabled = false
        addSubview(blur)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
    }

    /// Like the native camera while it switches formats or lenses: the picture softly blurs
    /// instead of freezing or flashing black.
    func setBlurred(_ blurred: Bool) {
        bringSubviewToFront(blur)
        UIView.animate(withDuration: blurred ? 0.15 : 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.blur.effect = blurred ? UIBlurEffect(style: .dark) : nil
        }
    }

    /// A still picture instead of the camera, for the demo.
    func showStill(_ image: UIImage) {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
}

/// Both camera pictures in one UIKit view. Layout changes animate on the render server with a
/// spring, so swapping and moving the small window cost the app no work per frame (SwiftUI
/// animating live video views frame by frame was what made v0.1 stutter).
final class DualPreviewContainer: UIView {
    let back = CameraPreviewView()
    let front = CameraPreviewView()
    /// Volume buttons (and Camera Control) start and stop recording, as in the native camera.
    var onCaptureButton: (() -> Void)?

    private var layoutState = DualLayout()
    private var insets = FrameInsets.uniform(12)
    private var dragOffset: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        for feed in [back, front] {
            feed.backgroundColor = .black
            feed.layer.cornerCurve = .continuous
            feed.layer.masksToBounds = true
            feed.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
            addSubview(feed)
        }
        if #available(iOS 17.2, *) {
            addInteraction(AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onCaptureButton?() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(layout: DualLayout, insets: FrameInsets, dragOffset: CGSize) {
        let changed = layout != layoutState || insets != self.insets
        // Letting go of the small window (or a new corner) animates; following the finger doesn't.
        let settling = dragOffset == .zero && self.dragOffset != .zero
        layoutState = layout
        self.insets = insets
        self.dragOffset = dragOffset
        guard changed || settling else {
            place()
            return
        }
        if window != nil, bounds.width > 0 {
            UIView.animate(springDuration: 0.4, bounce: 0.12, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.place()
            }
        } else {
            place()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    private func place() {
        guard bounds.width > 0 else { return }
        let frames = DualGeometry.frames(for: layoutState, in: bounds.size, insets: insets)
        position(back, in: frames.back, radius: frames.backRadius)
        position(front, in: frames.front, radius: frames.frontRadius)
        bringSubviewToFront(frames.frontOnTop ? front : back)

        let small: UIView? = layoutState.style == .pip ? (layoutState.backIsMain ? front : back) : nil
        for feed in [back, front] {
            feed.transform = feed === small
                ? CGAffineTransform(translationX: dragOffset.width, y: dragOffset.height)
                : .identity
        }
    }

    private func position(_ view: UIView, in frame: CGRect, radius: CGFloat) {
        // bounds and center rather than frame, since the small window may carry a drag transform.
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        view.layer.cornerRadius = radius
        view.layer.borderWidth = radius > 0 ? 1 : 0
    }
}

/// Puts the model's preview container on screen.
struct DualPreview: UIViewRepresentable {
    let container: DualPreviewContainer
    let layout: DualLayout
    let insets: FrameInsets
    let dragOffset: CGSize
    let onCaptureButton: () -> Void

    func makeUIView(context: Context) -> DualPreviewContainer {
        container.onCaptureButton = onCaptureButton
        return container
    }

    func updateUIView(_ view: DualPreviewContainer, context: Context) {
        view.onCaptureButton = onCaptureButton
        view.update(layout: layout, insets: insets, dragOffset: dragOffset)
    }
}
