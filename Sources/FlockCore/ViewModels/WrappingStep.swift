/// A step along a list that wraps from either end to the other.
public enum WrappingStep {
    /// `nil` when there is no other item to go to, or `current` is not in
    /// `items`.
    public static func neighbor<T: Equatable>(of current: T?, in items: [T], step: Int) -> T? {
        guard items.count > 1, let current, let index = items.firstIndex(of: current) else { return nil }
        return items[((index + step) % items.count + items.count) % items.count]
    }
}
