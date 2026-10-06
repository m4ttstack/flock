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
