import CoreImage
import Photos
import UIKit

/// Saves a dual photo: the back and front stills, and one combined picture laid out the way the
/// screen showed them (picture-in-picture or split), following the same Save setting as video.
enum PhotoSaver {
    struct Outcome {
        var thumbnail: UIImage?
        var message: String?
    }

    private static let context = CIContext(options: [.priorityRequestLow: true])

    static func save(_ photo: DualPhoto, layout: DualLayout, orientation: RecordOrientation,
                     format: PhotoFormat, save: SaveOption) async -> Outcome {
        guard photo.back != nil || photo.front != nil else {
            return Outcome(message: "The photo couldn't be taken")
        }
        var pictures: [Data] = []
        if save != .combined || photo.back == nil || photo.front == nil {
            pictures += [photo.back, photo.front].compactMap { $0 }
        }
        var combined: Data?
        if save != .angles, let back = photo.back, let front = photo.front {
            combined = compose(back: back, front: front, layout: layout, orientation: orientation, format: format)
            if let combined { pictures.append(combined) }
        }
        let thumbnail = (combined ?? photo.back ?? photo.front).flatMap { UIImage(data: $0) }
            .flatMap { $0.preparingThumbnail(of: CGSize(width: 240, height: 240)) }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return Outcome(thumbnail: thumbnail, message: "Allow DualShot to add to Photos in Settings to save photos")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for data in pictures {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }
            return Outcome(thumbnail: thumbnail)
        } catch {
            return Outcome(thumbnail: thumbnail, message: "Couldn't save to Photos")
        }
    }

    /// One picture with both cameras, using the same geometry as the combined video.
    static func compose(back: Data, front: Data, layout: DualLayout, orientation: RecordOrientation,
                        format: PhotoFormat) -> Data? {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let backImage = CIImage(data: back, options: options), let frontImage = CIImage(data: front, options: options) else {
            return nil
        }
        let backUpright = backImage.transformed(by: CGAffineTransform(translationX: -backImage.extent.minX, y: -backImage.extent.minY))
        let frontUpright = frontImage.transformed(by: CGAffineTransform(translationX: -frontImage.extent.minX, y: -frontImage.extent.minY))
        let canvas = backUpright.extent.size
        var turned = orientation
        if turned.isLandscape != (canvas.width > canvas.height) {
            turned = canvas.width > canvas.height ? .landscapeLeft : .portrait
        }
        let frames = DualGeometry.frames(for: layout, canvas: canvas, orientation: turned)
        let bounds = CGRect(origin: .zero, size: canvas)
        var image = CIImage(color: .black).cropped(to: bounds)
        let backLayer = (backUpright, frames.back, frames.backRadius)
        let frontLayer = (frontUpright, frames.front, frames.frontRadius)
        for (picture, rect, radius) in frames.frontOnTop ? [backLayer, frontLayer] : [frontLayer, backLayer] {
            image = DualCompositor.place(picture, in: rect, radius: radius, over: image, canvas: canvas)
        }
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return format == .heif
            ? context.heifRepresentation(of: image, format: .RGBA8, colorSpace: space)
            : context.jpegRepresentation(of: image, colorSpace: space)
    }
}
