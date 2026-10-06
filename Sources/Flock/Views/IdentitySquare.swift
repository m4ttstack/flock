import FlockCore
import SwiftUI

extension Theme {
    /// A herd has no identity colour and draws in the label grey.
    func identityInk(_ identity: Color?) -> Color {
        identity ?? textLabel
    }

    /// The ground of an Arrange island and of an Overview group.
    func identityTint(_ identity: Color?) -> Color {
        identityInk(identity).opacity(ChromeMetrics.Grid.islandTint)
    }
}

/// A workspace's right-click Colour menu: the eight identity hues and
/// Automatic. Empty for a herd, which has no key and draws neutral.
struct IdentityColourMenu: View {
    let theme: Theme
    let key: String?

    @Environment(WorkspaceIdentityStore.self) private var identityStore

    var body: some View {
        if let key {
            let colors = IdentityPalette.colors(for: theme.palette)
            ForEach(Array(colors.enumerated()), id: \.offset) { index, rgb in
                Button {
                    identityStore.setOverride(index, for: key)
                } label: {
                    Label { Text("Colour \(index + 1)") } icon: { Image(nsImage: IdentitySwatch.image(rgb)) }
                }
                .accessibilityIdentifier("flock.identity.colour.\(index)")
            }
            Divider()
            Button("Automatic") { identityStore.setOverride(nil, for: key) }
                .accessibilityIdentifier("flock.identity.colour.automatic")
        }
    }
}

/// The identity colours as menu images: a menu draws a symbol as a template,
/// which would drop the very colour the item names.
private enum IdentitySwatch {
    static func image(_ rgb: RGB) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(
                srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1
            ).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The square that marks a workspace by its identity colour.
struct IdentitySquare: View {
    let theme: Theme
    let identity: Color?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.identityInk(identity))
            .frame(width: size, height: size)
    }
}
