// Generates Sources/Flock/Resources/Assets.xcassets/AppIcon-Dev.appiconset
// from the production AppIcon: the same artwork with a DEV band across its
// foot, so Flock Dev never passes for the release in the Dock or a Finder
// window. Run after changing the production icon:
//
//   swift Scripts/make-dev-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Sources/Flock/Resources/Assets.xcassets")
let source = assets.appendingPathComponent("AppIcon.appiconset")
let output = assets.appendingPathComponent("AppIcon-Dev.appiconset")

// herdr's "working" amber on the icon's own ground, so the band reads as part
// of the mark rather than a sticker on it.
let bandColor = NSColor(srgbRed: 0xE0 / 255, green: 0xAF / 255, blue: 0x68 / 255, alpha: 1)
let textColor = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1E / 255, alpha: 1)

func bitmap(side: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// The badged icon at 1024 px, from the production master.
func master() -> NSBitmapImageRep {
    let side = 1024
    let art = NSImage(contentsOf: source.appendingPathComponent("icon_512x512@2x.png"))!
    let rep = bitmap(side: side)
    let full = NSRect(x: 0, y: 0, width: side, height: side)
    draw(into: rep) {
        art.draw(in: full)
        // Painted only where the icon is already opaque, so the band takes the
        // rounded square's own corners.
        let band = NSRect(x: 0, y: 92, width: side, height: 150)
        bandColor.setFill()
        band.fill(using: .sourceAtop)

        let font = NSFont.systemFont(ofSize: 104, weight: .heavy)
        let label = NSAttributedString(string: "DEV", attributes: [
            .font: font, .foregroundColor: textColor, .kern: 18,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2 + 9, y: band.midY - size.height / 2 + 4))
    }
    return rep
}

let masterRep = master()
let masterImage = NSImage(size: NSSize(width: 1024, height: 1024))
masterImage.addRepresentation(masterRep)

try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let manifest = try Data(contentsOf: source.appendingPathComponent("Contents.json"))
let images = (try JSONSerialization.jsonObject(with: manifest) as! [String: Any])["images"] as! [[String: String]]
for image in images {
    guard let filename = image["filename"], let size = image["size"], let scale = image["scale"] else { continue }
    let points = Int(size.split(separator: "x")[0])!
    let pixels = points * Int(scale.dropLast())!
    let rep = bitmap(side: pixels)
    draw(into: rep) { masterImage.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)) }
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}
try manifest.write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(output.path)")
