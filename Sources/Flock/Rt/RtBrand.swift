import FlockCore
import SwiftUI

/// rt's own colours: pink on plum, as its terminal UI draws itself. The same
/// in every theme.
enum RtBrand {
    static let plum = Color(red: 22 / 255, green: 18 / 255, blue: 36 / 255)
    static let pink = Color(red: 1, green: 107 / 255, blue: 157 / 255)
}

enum RtAvailability {
    /// Read once: every pane's legend asks, and the answer is the startup
    /// PATH's, which does not change for the life of the process.
    static let installed = NavigatorRoster.detected() != nil
}

/// The "rt" mark every rt surface carries: the legend's button in each state
/// and the popover's header, at its own size and face.
struct RtBadge: View {
    var size = ChromeMetrics.RtButton.badgeSize
    var font = ChromeType.rtBadge

    var body: some View {
        Text("rt")
            .font(font)
            .foregroundStyle(RtBrand.pink)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.RtButton.badgeCornerRadius).fill(RtBrand.plum))
    }
}
