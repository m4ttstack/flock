import SwiftUI

extension ChromeMetrics {
    enum EmptyPin {
        static let mark: CGFloat = 30
        static let identitySpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 26
        /// Raised off true centre: a mark above and a caption below make a
        /// group centred by its frame read low.
        static let lift: CGFloat = 45
    }

    enum PinFolderPopover {
        static let width: CGFloat = 340
        static let verticalPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 14
        static let rowSpacing: CGFloat = 2
        static let rowVerticalPadding: CGFloat = 7
        static let titleSpacing: CGFloat = 8
        static let titleBottomPadding: CGFloat = 4
        static let radio: CGFloat = 12
        static let ring: CGFloat = 1.5
        static let pickedRing: CGFloat = 4
        /// Lines Other up with the folders, past the radio.
        static let otherLeading: CGFloat = horizontalPadding + radio + titleSpacing
        static let otherVerticalPadding: CGFloat = 6
    }
}
