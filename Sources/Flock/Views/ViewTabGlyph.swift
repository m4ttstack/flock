import FlockCore
import SwiftUI

/// A view tab's glyph, outlined: a panel with its rail, three columns, a
/// two-by-two grid. Drawn rather than taken from SF Symbols so the three share
/// one stroke weight and one outer box.
struct ViewTabGlyph: View {
    let tab: ViewTab

    var body: some View {
        ViewTabOutline(tab: tab)
            .stroke(style: StrokeStyle(lineWidth: ChromeMetrics.TitleBar.tabGlyphStroke, lineCap: .round, lineJoin: .round))
            // Half a stroke in from every edge, so the outline stays inside the frame.
            .padding(ChromeMetrics.TitleBar.tabGlyphStroke / 2)
    }
}

private struct ViewTabOutline: Shape {
    let tab: ViewTab

    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.18
        var path = Path()
        switch tab {
        case .workspaces:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            let x = rect.minX + rect.width * 0.36
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        case .overview:
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            for fraction in [1.0 / 3, 2.0 / 3] {
                let x = rect.minX + rect.width * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
        case .arrange:
            let gap = rect.width * 0.2
            let cell = (rect.width - gap) / 2
            let cellRadius = cell * 0.25
            for row in 0..<2 {
                for column in 0..<2 {
                    let origin = CGPoint(
                        x: rect.minX + CGFloat(column) * (cell + gap),
                        y: rect.minY + CGFloat(row) * (cell + gap)
                    )
                    path.addRoundedRect(
                        in: CGRect(origin: origin, size: CGSize(width: cell, height: cell)),
                        cornerSize: CGSize(width: cellRadius, height: cellRadius)
                    )
                }
            }
        }
        return path
    }
}
