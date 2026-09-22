import AppKit
import CoreGraphics
import Foundation

// The install window's backdrop: flock's ground, and an arrow pointing from
// where the app sits to where it is meant to go. Drawn rather than shipped as
// a binary asset, the same way Scripts/make-icon.swift draws the icon, so the
// palette lives in one language and a colour change is an edit rather than a
// round trip through an image editor.
//
// The geometry here and the --icon / --app-drop-link positions in
// release-build.sh describe the same window and have to agree. They are
// expressed in the same coordinate system (points, origin top-left, matching
// what create-dmg passes to Finder), so a change to one is a change to both.

let windowSize = CGSize(width: 540, height: 380)
let iconCenterY: CGFloat = 190
let appIconCenterX: CGFloat = 140
let dropLinkCenterX: CGFloat = 400

// Lighter than the icon's own ground on purpose. At the icon's exact values
// the app's dark squircle sinks into the window and loses its edge, and this
// is the one surface where that icon has to read as a thing you can pick up
// and move.
// Light, despite flock being a dark app, because Finder draws the icon
// labels itself and colours them from the system appearance rather than from
// this image. On a dark ground a Light-mode user gets near-black text on
// near-black and cannot read either name. The app's own dark icon carries
// the brand here instead, and reads better against light than it did against
// a ground close to its own.
let ground = NSColor(srgbRed: 0.957, green: 0.953, blue: 0.973, alpha: 1).cgColor
let groundLow = NSColor(srgbRed: 0.890, green: 0.886, blue: 0.918, alpha: 1).cgColor
// Deeper and more opaque than the icon's lilac, which disappears on a light
// ground.
let arrow = NSColor(srgbRed: 0.435, green: 0.306, blue: 0.702, alpha: 0.75).cgColor

/// Between the two icons, clear of both. 128pt icons plus their labels, so
/// the arrow starts and ends well outside them rather than touching.
let arrowInset: CGFloat = 96

func render(scale: CGFloat, to url: URL) {
    let pixelWidth = Int(windowSize.width * scale)
    let pixelHeight = Int(windowSize.height * scale)
    let ctx = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)

    let bounds = CGRect(origin: .zero, size: windowSize)
    ctx.saveGState()
    ctx.clip(to: bounds)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [ground, groundLow] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: windowSize.height), end: CGPoint(x: 0, y: 0), options: []
    )
    ctx.restoreGState()

    // CoreGraphics counts y up from the bottom; the icon positions are stated
    // top-down to match Finder, so the arrow's line is converted once here
    // rather than every caller having to remember which way is which.
    let y = windowSize.height - iconCenterY
    let startX = appIconCenterX + arrowInset
    let endX = dropLinkCenterX - arrowInset

    // One closed path, filled once. A stroked stem plus a filled head
    // overlap where they meet, and at less than full alpha that overlap
    // paints twice and shows as a seam through the head.
    let halfStem: CGFloat = 1.5
    let headLength: CGFloat = 18
    let halfHead: CGFloat = 11
    let headBase = endX - headLength

    ctx.setFillColor(arrow)
    ctx.move(to: CGPoint(x: startX, y: y - halfStem))
    ctx.addLine(to: CGPoint(x: headBase, y: y - halfStem))
    ctx.addLine(to: CGPoint(x: headBase, y: y - halfHead))
    ctx.addLine(to: CGPoint(x: endX, y: y))
    ctx.addLine(to: CGPoint(x: headBase, y: y + halfHead))
    ctx.addLine(to: CGPoint(x: headBase, y: y + halfStem))
    ctx.addLine(to: CGPoint(x: startX, y: y + halfStem))
    ctx.closePath()
    ctx.fillPath()

    let image = ctx.makeImage()!
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// Finder reads the @2x variant from the same folder by name, so a Retina
// screen gets the sharp one without the DMG carrying two backgrounds.
render(scale: 1, to: out.appendingPathComponent("dmg-background.png"))
render(scale: 2, to: out.appendingPathComponent("dmg-background@2x.png"))
print("wrote dmg-background.png and dmg-background@2x.png to \(out.path)")
