import CoreGraphics
import FlockCore
import Foundation
import ImageIO

/// A handle's face, decoded and ready to draw. `CGImage` is immutable.
struct ChatFaceImage: @unchecked Sendable {
    let image: CGImage
    let zoom: CGFloat
    let isFinal: Bool

    /// The chip's face at 2x.
    static let pixelSize = Int(ChromeMetrics.PaneBar.faceSize) * 2

    @Sendable
    static func load(handle: String) async -> ChatFaceImage? {
        guard let avatar = await ChatToolLocator.avatar(handle: handle, size: pixelSize) else { return nil }
        return await Task.detached(priority: .utility) {
            decode(avatar, handle: handle)
        }.value
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
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
        return drawn ? CGFloat(ChatFaceZoom.zoom(rgba: rgba)) : 1
    }
}
