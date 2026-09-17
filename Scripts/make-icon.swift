import AppKit
import CoreGraphics
import Foundation

let ground = NSColor(srgbRed: 0.102, green: 0.106, blue: 0.149, alpha: 1).cgColor
let groundLow = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.094, alpha: 1).cgColor
// The leader, then its echoes: one hue per step, the way a 70s motion trail
// separates into colour as it lags behind the subject.
let trail: [CGColor] = [
    NSColor(srgbRed: 0.416, green: 0.541, blue: 0.937, alpha: 1).cgColor,
    NSColor(srgbRed: 0.639, green: 0.478, blue: 0.937, alpha: 1).cgColor,
    NSColor(srgbRed: 0.878, green: 0.518, blue: 0.831, alpha: 1).cgColor,
]
let mark = NSColor(srgbRed: 0.847, green: 0.678, blue: 0.996, alpha: 1).cgColor

func squircle(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
}

func render(size: CGFloat, to url: URL) {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = size * 0.086
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    ctx.saveGState()
    ctx.addPath(squircle(in: body))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [ground, groundLow] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Fit the ram inside the squircle with its own margin, centred on its
    // real bounds rather than on the 512 canvas the asset was exported at.
    let ram = HerdrRam.path()
    let bounds = ram.boundingBoxOfPath
    let margin = body.width * 0.19
    let target = body.insetBy(dx: margin, dy: margin)
    let scale = target.height / bounds.height * 0.87

    /// Places the ram at a scale and offset inside the tile, flipping y
    /// because the asset's own transform leaves it in SVG's y-down space.
    func placed(scale: CGFloat, dx: CGFloat, dy: CGFloat) -> CGPath {
        var fit = CGAffineTransform(translationX: target.midX - bounds.midX * scale + dx - target.width * 0.13,
                                    y: target.midY + bounds.midY * scale + dy - target.height * 0.05)
            .scaledBy(x: scale, y: -scale)
        return ram.copy(using: &fit)!
    }

    ctx.addPath(squircle(in: body))
    ctx.clip()

    func fill(_ path: CGPath, color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // Echoes at the SAME size as the leader, stepping back along one axis:
    // a motion trail reads as one animal moving, where scaling each copy down
    // would read as three animals standing at different distances.
    for (index, color) in trail.enumerated() {
        let back = CGFloat(trail.count - index)
        ctx.setAlpha(0.58 + 0.13 * CGFloat(index))
        fill(placed(scale: scale, dx: target.width * 0.105 * back, dy: target.height * 0.075 * back), color: color)
    }
    ctx.setAlpha(1)
    fill(placed(scale: scale, dx: 0, dy: 0), color: mark)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

// macOS wants both scales of each slot. The set is written whole, Contents
// included, so regenerating never leaves a half-updated catalog behind.
struct Slot {
    let size: Int
    let scale: Int
    var pixels: Int { size * scale }
    var file: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for slot in slots {
    render(size: CGFloat(slot.pixels), to: out.appendingPathComponent(slot.file))
}

let images = slots.map { slot in
    """
        {
          "filename" : "\(slot.file)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.size)x\(slot.size)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(slots.count) icons to \(out.path)")
