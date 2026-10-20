import FlockCore
import SwiftUI

extension HerdrSessionEntry {
    /// One `Text`: a menu item with two `Text`s renders the second as a subtitle line.
    var menuTitle: Text { Text(name) + Text("  \(statusLabel)").foregroundStyle(.secondary) }
}
