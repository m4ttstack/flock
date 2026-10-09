import FlockCore
import SwiftUI

/// A view tab's glyph. SF Symbols has no solid sidebar-and-content symbol,
/// and the outlined ones read lighter than Overview's and Arrange's solid
/// glyphs, so Workspaces draws its own: a rail beside a pane, laid into the
/// bounds its stand-in symbol occupies so all three sit at one size.
struct ViewTabGlyph: View {
    let tab: ViewTab

    var body: some View {
        if tab == .workspaces {
            Image(systemName: tab.symbolName)
                .resizable()
                .scaledToFit()
                .hidden()
                .overlay { WorkspacesGlyph() }
        } else {
            Image(systemName: tab.symbolName)
                .resizable()
                .scaledToFit()
        }
    }
}

/// Proportions follow `rectangle.split.3x1.fill`, Overview's glyph: the same
/// gap between blocks and the same corner rounding.
private struct WorkspacesGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let gap = size.width * 0.09
            let rail = size.width * 0.27
            let radius = size.height * 0.2
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).frame(width: rail)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
            }
        }
    }
}
