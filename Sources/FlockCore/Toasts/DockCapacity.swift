import Foundation

/// How many attention cards the rail's dock draws: every one when they fit,
/// otherwise as many as fit over the "more" pill, never fewer than
/// `AttentionToastStack.minimumVisible`.
///
/// The dock grows into at most `maximumShareOfRail` of the rail's height, so
/// the lists above it always keep the rest however busy the dock gets.
public enum DockCapacity {
    public static let maximumShareOfRail = 0.4

    /// Heights in points. `fixedHeight` is everything in the dock that is not
    /// a card or the pill: its rule, its insets, and the notice when there is
    /// one, with the notice's spacing below it.
    public static func cardLimit(
        cards: Int, railHeight: Double, fixedHeight: Double,
        cardHeight: Double, pillHeight: Double, spacing: Double
    ) -> Int {
        let floor = AttentionToastStack.minimumVisible
        guard cards > floor, cardHeight > 0 else { return min(cards, floor) }
        let room = railHeight * maximumShareOfRail - fixedHeight
        func height(cards count: Int, pill: Bool) -> Double {
            let items = count + (pill ? 1 : 0)
            return Double(count) * cardHeight + (pill ? pillHeight : 0) + Double(max(0, items - 1)) * spacing
        }
        if height(cards: cards, pill: false) <= room { return cards }
        var fitting = cards - 1
        while fitting > floor, height(cards: fitting, pill: true) > room {
            fitting -= 1
        }
        return fitting
    }
}
