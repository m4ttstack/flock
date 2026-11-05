import CoreGraphics
import FlockCore
import Foundation
import ImageIO

enum ChatFaceLoad: Sendable {
    case face(ChatFaceImage)
    case noFace
    case noVerb
}

/// A handle's face, decoded and ready to draw. `CGImage` is immutable.
struct ChatFaceImage: @unchecked Sendable {
    let image: CGImage
    let zoom: CGFloat
    let isFinal: Bool

    /// The chip's face at 2x.
    static let pixelSize = Int(ChromeMetrics.PaneBar.faceSize) * 2

    @Sendable
    static func load(handle: String) async -> ChatFaceLoad {
        switch await ChatToolLocator.avatar(handle: handle, size: pixelSize) {
        case .noVerb, nil: return .noVerb
        case .noFace: return .noFace
        case let .face(avatar):
            let face = await Task.detached(priority: .utility) { decode(avatar, handle: handle) }.value
            return face.map(ChatFaceLoad.face) ?? .noFace
        }
    }

    static func decode(_ avatar: ChatAvatar, handle: String) -> ChatFaceImage? {
        let url = URL(fileURLWithPath: avatar.path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        // Slack photos keep their own size, however large that is.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Cropped to the square the chip shows, so side bars are measured
        // against what is drawn.
        let side = min(thumbnail.width, thumbnail.height)
        let square = CGRect(x: (thumbnail.width - side) / 2, y: (thumbnail.height - side) / 2, width: side, height: side)
        let image = thumbnail.cropping(to: square) ?? thumbnail
        let zoom = avatar.kind == .slack ? sidebarZoom(image) : 1
        return ChatFaceImage(image: image, zoom: zoom, isFinal: avatar.isFinal(for: handle))
    }

    private static func sidebarZoom(_ image: CGImage) -> CGFloat {
        let size = ChatFaceZoom.sampleSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return 1 }
        // CoreGraphics only draws premultiplied; the chat app judges straight colour.
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[pixel + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in pixel..<(pixel + 3) {
                rgba[channel] = UInt8(min(255, Int(rgba[channel]) * 255 / alpha))
            }
        }
        return CGFloat(ChatFaceZoom.zoom(rgba: rgba))
    }
}
